#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

from secure_model_api.crypto import (
    ModelCryptoError,
    encrypt_model,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Encrypt a model artifact with AES-256-GCM."
    )
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--key-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    try:
        plaintext = args.input.read_bytes()
        encoded_key = args.key_file.read_text(
            encoding="ascii"
        ).strip()

        encrypted_model = encrypt_model(
            plaintext,
            encoded_key,
        )

        args.output.parent.mkdir(
            parents=True,
            exist_ok=True,
        )
        args.output.write_bytes(encrypted_model)
        args.output.chmod(0o444)

    except (OSError, UnicodeError, ModelCryptoError) as exc:
        raise SystemExit(
            f"Model encryption failed: {exc}"
        ) from exc

    print(
        "PASS: encrypted model artifact created "
        f"({len(encrypted_model)} bytes)."
    )


if __name__ == "__main__":
    main()