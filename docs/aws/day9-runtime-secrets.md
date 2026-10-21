# Day 9: AWS-backed runtime secrets

## Configuration

- AWS region: ap-south-1.
- CLI profile: secure-ai-dev; IAM user: secure-api.
- Secret: secure-ai/day9/model-key.
- Verified image: secure-model-api:dev-local.
- The same key failed authentication against CI image f316b8aabd58.
  Image and key selection must therefore stay paired.

## Files

- scripts/run-model-api-aws.sh retrieves the key and launches the API.
- aws/iam/day9-model-secret-policy.json records the Day 9 lab permissions.
  The console inline policy is named SecureAI-Day9-ModelSecret.

## Runtime flow

1. The launcher checks the AWS identity and resolves the local image ID.
2. AWS CLI retrieves the secret using the host's temporary credentials.
3. The key is written to a private temporary directory under /dev/shm.
4. Docker mounts the key read-only at /run/secrets/model-key.
5. The application authenticates and decrypts its encrypted model into tmpfs.
6. Stopping the launcher removes its container and temporary key directory.

AWS authentication happens on the WSL host. The application reads its
runtime key through the existing MODEL_KEY_FILE interface.

## Run from the repository root

Refresh the temporary login when required:

    aws login --profile secure-ai-dev --region ap-south-1 --remote

Start the API:

    ./scripts/run-model-api-aws.sh

Leave that terminal open. Check the API from another terminal:

    curl -fsS http://127.0.0.1:8000/health
    curl -fsS http://127.0.0.1:8000/ready

Press Ctrl+C in the launcher terminal to stop and clean up.

## Verified results

- Health returned healthy; readiness confirmed the model was loaded.
- Runtime UID and GID were 1000, matching the non-root WSL user.
- Key and decrypted model permissions were 600; both files used tmpfs.
- Root filesystem and key mount were read-only.
- All Linux capabilities were dropped; no-new-privileges was enabled.
- Temporary container and local key directory were removed after stopping.

## Retained AWS resource

The Secrets Manager secret remains stored after local runtime cleanup.
Application deployment to AWS and workload-role authentication are future work.
