# Secure Model API

A production-style FastAPI service demonstrating secure model packaging and runtime loading.

## Security flow

```mermaid
flowchart TD
    A["Plain model outside Git"] --> B["BuildKit secret mount"]
    K["Build key outside Git"] --> B
    B --> C["AES-256-GCM model.enc"]
    C --> D["Hardened runtime image"]
    R["Runtime key file"] --> E["Authenticated tmpfs decryption"]
    D --> E
    E --> F["Non-root FastAPI service"]