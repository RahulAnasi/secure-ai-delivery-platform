from __future__ import annotations

import base64
import os
import unittest

from secure_model_api.crypto import (
    ModelCryptoError,
    decrypt_model,
    encrypt_model,
)


class ModelCryptoTests(unittest.TestCase):
    def setUp(self) -> None:
        self.key = base64.b64encode(
            os.urandom(32)
        ).decode("ascii")

    def test_encrypt_decrypt_round_trip(self) -> None:
        plaintext = b'{"model": "test"}'

        encrypted = encrypt_model(
            plaintext,
            self.key,
        )

        self.assertNotEqual(encrypted, plaintext)
        self.assertEqual(
            decrypt_model(encrypted, self.key),
            plaintext,
        )

    def test_incorrect_key_is_rejected(self) -> None:
        encrypted = encrypt_model(
            b"protected model",
            self.key,
        )

        incorrect_key = base64.b64encode(
            os.urandom(32)
        ).decode("ascii")

        with self.assertRaises(ModelCryptoError):
            decrypt_model(
                encrypted,
                incorrect_key,
            )

    def test_tampered_ciphertext_is_rejected(self) -> None:
        encrypted = bytearray(
            encrypt_model(
                b"protected model",
                self.key,
            )
        )
        encrypted[-1] ^= 1

        with self.assertRaises(ModelCryptoError):
            decrypt_model(
                bytes(encrypted),
                self.key,
            )

    def test_non_256_bit_key_is_rejected(self) -> None:
        short_key = base64.b64encode(
            os.urandom(16)
        ).decode("ascii")

        with self.assertRaises(ModelCryptoError):
            encrypt_model(
                b"protected model",
                short_key,
            )


if __name__ == "__main__":
    unittest.main()