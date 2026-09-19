from __future__ import annotations

import base64
import binascii
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


MODEL_MAGIC = b"SAIDP01"
NONCE_LENGTH = 12
AUTH_TAG_LENGTH = 16
ASSOCIATED_DATA = b"secure-ai-delivery-platform:model:v1"


class ModelCryptoError(ValueError):
    """Raised when model encryption or decryption cannot be completed safely."""


def decode_key(encoded_key: str) -> bytes:
    """Decode and validate a Base64-encoded AES-256 key."""

    try:
        key = base64.b64decode(encoded_key.strip(), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ModelCryptoError("Model key is not valid Base64.") from exc

    if len(key) != 32:
        raise ModelCryptoError("Model key must decode to exactly 32 bytes.")

    return key


def encrypt_model(plaintext: bytes, encoded_key: str) -> bytes:
    """Encrypt model bytes with AES-256-GCM."""

    if not plaintext:
        raise ModelCryptoError("Plaintext model is empty.")

    key = decode_key(encoded_key)
    nonce = os.urandom(NONCE_LENGTH)
    ciphertext = AESGCM(key).encrypt(
        nonce,
        plaintext,
        ASSOCIATED_DATA,
    )

    return MODEL_MAGIC + nonce + ciphertext


def decrypt_model(encrypted_model: bytes, encoded_key: str) -> bytes:
    """Authenticate and decrypt an encrypted model."""

    minimum_length = (
        len(MODEL_MAGIC)
        + NONCE_LENGTH
        + AUTH_TAG_LENGTH
    )

    if len(encrypted_model) < minimum_length:
        raise ModelCryptoError("Encrypted model is incomplete.")

    if not encrypted_model.startswith(MODEL_MAGIC):
        raise ModelCryptoError("Encrypted model format is unsupported.")

    key = decode_key(encoded_key)
    nonce_start = len(MODEL_MAGIC)
    nonce_end = nonce_start + NONCE_LENGTH

    nonce = encrypted_model[nonce_start:nonce_end]
    ciphertext = encrypted_model[nonce_end:]

    try:
        return AESGCM(key).decrypt(
            nonce,
            ciphertext,
            ASSOCIATED_DATA,
        )
    except InvalidTag as exc:
        raise ModelCryptoError(
            "Model authentication failed."
        ) from exc