# ADR 0001: Promote One Immutable Artifact

## Status

Accepted

## Context

Rebuilding an application separately for development, test and production can produce different binaries or image layers from the same source. This weakens test evidence and makes production failures harder to reproduce.

## Decision

The delivery pipeline will build the application image once.

The image will:

- Receive an immutable tag derived from the Git commit.
- Be identified and promoted by its digest.
- Pass testing and security gates before promotion.
- Move unchanged from development to test and production.
- Use environment-specific configuration and secret references at runtime.

Mutable tags such as `latest` may be used only as convenient aliases. Deployments must reference an immutable tag or digest.

## Consequences

### Benefits

- Test results apply to the production artifact.
- Rollback targets are unambiguous.
- Artifact provenance is easier to audit.
- Environment drift is reduced.

### Trade-offs

- Promotion metadata must be managed.
- Configuration must remain separate from the image.
- Emergency changes still require a new build and validation cycle.