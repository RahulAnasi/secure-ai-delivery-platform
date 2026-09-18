# Jenkins Credential Handling

## Purpose

Jenkins Credentials stores secrets required temporarily during CI/CD. Secret values must never be committed to Git, embedded in images, written to artifacts or printed in build logs.

## Current credential inventory

| Credential ID | Type | Environment | Purpose |
|---|---|---|---|
| `model-build-key-dev` | Secret text | Development | Encrypt model artifacts during the build |

This inventory records credential metadata only. It must never contain secret values.

## Pipeline rules

- Reference credentials using stable credential IDs.
- Bind credentials only around the commands that require them.
- Use `withCredentials` instead of global environment variables.
- Use single-quoted Groovy strings so the shell, not Groovy, expands variables.
- Disable shell tracing with `set +x` before processing a secret.
- Never print, transform, fingerprint or debug secret values.
- Never pass secrets through Git, `.env` files, Dockerfiles or build arguments.
- Do not archive workspaces or files containing decrypted secrets.
- Treat Jenkins log masking as a secondary safeguard, not the primary security control.

## Environment separation

Development, test and production must use different credentials. A development credential must never decrypt or deploy production assets.

Planned IDs:

- `model-build-key-dev`
- `model-build-key-test`
- `model-build-key-prod`

Production access will require tighter authorization and approval controls.

## Runtime boundary

Jenkins Credentials protects pipeline-time secrets. It is not the permanent runtime vault for the application.

Runtime workloads will use workload identity, AWS KMS and AWS Secrets Manager. The application must not depend on a Jenkins credential after deployment.

## Rotation procedure

1. Generate a new high-entropy secret.
2. Update the existing Jenkins credential while keeping its stable ID.
3. Clear temporary clipboard or local copies.
4. Run the validation pipeline.
5. Re-encrypt dependent artifacts before retiring an old encryption key.
6. Record the rotation without recording the secret value.

## Exposure response

If a secret is exposed:

1. Stop affected pipelines.
2. Revoke or rotate the credential immediately.
3. Inspect Git history, build logs, workspaces and archived artifacts.
4. Remove accessible copies where possible.
5. Re-encrypt affected artifacts if required.
6. Record the incident and corrective actions.

## Current lab limitation

The development credential currently has global scope on an isolated local Jenkins controller. A shared production controller should use folder-scoped credentials, role-based access, audit logging and separate credentials for each environment.