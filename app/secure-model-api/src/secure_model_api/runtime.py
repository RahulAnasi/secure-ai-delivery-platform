from __future__ import annotations

import json
import math
import os
from pathlib import Path
from typing import Any

from secure_model_api.crypto import (
    ModelCryptoError,
    decrypt_model,
)


class ModelRuntimeError(RuntimeError):
    """Raised when the runtime model cannot be loaded or used."""


class ModelRuntime:
    def __init__(
        self,
        encrypted_model_path: Path,
        decrypted_model_path: Path,
        key_file: Path,
    ) -> None:
        self.encrypted_model_path = encrypted_model_path
        self.decrypted_model_path = decrypted_model_path
        self.key_file = key_file
        self._model: dict[str, Any] | None = None

    @classmethod
    def from_environment(cls) -> "ModelRuntime":
        return cls(
            encrypted_model_path=Path(
                os.getenv(
                    "ENCRYPTED_MODEL_PATH",
                    "/app/models/model.enc",
                )
            ),
            decrypted_model_path=Path(
                os.getenv(
                    "DECRYPTED_MODEL_PATH",
                    "/dev/shm/model.bin",
                )
            ),
            key_file=Path(
                os.getenv(
                    "MODEL_KEY_FILE",
                    "/run/secrets/model-key",
                )
            ),
        )

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def load(self) -> dict[str, Any]:
        try:
            encrypted_model = self.encrypted_model_path.read_bytes()
            encoded_key = self.key_file.read_text(
                encoding="ascii"
            ).strip()

            try:
                plaintext = decrypt_model(
                    encrypted_model,
                    encoded_key,
                )
            finally:
                del encoded_key

            self._write_decrypted_file(plaintext)
            model = json.loads(plaintext.decode("utf-8"))
            self._validate_model(model)

        except (
            OSError,
            UnicodeError,
            json.JSONDecodeError,
            ModelCryptoError,
            ModelRuntimeError,
        ) as exc:
            self.cleanup()
            raise ModelRuntimeError(
                f"Secure model initialization failed: {exc}"
            ) from exc

        self._model = model
        return model

    def predict(self, features: list[float]) -> dict[str, Any]:
        if self._model is None:
            raise ModelRuntimeError("Model is not loaded.")

        weights = self._model["weights"]

        if len(features) != len(weights):
            raise ModelRuntimeError(
                f"Expected {len(weights)} input features."
            )

        score = float(self._model["bias"]) + sum(
            float(weight) * feature
            for weight, feature in zip(
                weights,
                features,
                strict=True,
            )
        )

        positive_probability = self._sigmoid(score)
        labels = self._model["labels"]

        if positive_probability >= 0.5:
            label = labels[1]
            confidence = positive_probability
        else:
            label = labels[0]
            confidence = 1.0 - positive_probability

        return {
            "model_version": self._model["version"],
            "label": label,
            "confidence": round(confidence, 6),
            "score": round(score, 6),
        }

    def cleanup(self) -> None:
        self._model = None

        try:
            self.decrypted_model_path.unlink(missing_ok=True)
        except OSError as exc:
            raise ModelRuntimeError(
                "Could not remove decrypted model."
            ) from exc

    def _write_decrypted_file(self, plaintext: bytes) -> None:
        self.decrypted_model_path.parent.mkdir(
            parents=True,
            exist_ok=True,
        )
        self.decrypted_model_path.unlink(missing_ok=True)

        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL

        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW

        file_descriptor = os.open(
            self.decrypted_model_path,
            flags,
            0o600,
        )

        with os.fdopen(file_descriptor, "wb") as model_file:
            model_file.write(plaintext)
            model_file.flush()

    @staticmethod
    def _validate_model(model: Any) -> None:
        if not isinstance(model, dict):
            raise ModelRuntimeError("Model must be a JSON object.")

        required_fields = {
            "name",
            "version",
            "labels",
            "bias",
            "weights",
        }

        if not required_fields.issubset(model):
            raise ModelRuntimeError(
                "Model is missing required fields."
            )

        if (
            not isinstance(model["labels"], list)
            or len(model["labels"]) != 2
            or not all(
                isinstance(label, str) and label
                for label in model["labels"]
            )
        ):
            raise ModelRuntimeError(
                "Model labels are invalid."
            )

        if (
            not isinstance(model["weights"], list)
            or not model["weights"]
            or not all(
                isinstance(value, (int, float))
                and not isinstance(value, bool)
                for value in model["weights"]
            )
        ):
            raise ModelRuntimeError(
                "Model weights are invalid."
            )

        if (
            not isinstance(model["bias"], (int, float))
            or isinstance(model["bias"], bool)
        ):
            raise ModelRuntimeError("Model bias is invalid.")

    @staticmethod
    def _sigmoid(value: float) -> float:
        if value >= 0:
            exponential = math.exp(-value)
            return 1.0 / (1.0 + exponential)

        exponential = math.exp(value)
        return exponential / (1.0 + exponential)