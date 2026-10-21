# Day 8: AWS foundation

## Purpose

Establish working access to real AWS and practise secure storage
before connecting AWS services to the application.

## Access configuration

- Region: ap-south-1 (Mumbai).
- CLI profile: secure-ai-dev.
- IAM user: secure-api.
- Authentication: browser-based temporary sessions using aws login.
- SignInLocalDevelopmentAccess enables CLI browser login.
- SecureAI-Day8-Foundation grants access to the named practice
  bucket and secret.
- The user's existing capstone-builders group permissions also apply.

## What we verified

- STS confirmed that CLI commands ran as secure-api.
- Created bucket secure-ai-day8-884596874125 in Mumbai.
- Verified all four S3 Block Public Access settings were enabled.
- Verified BucketOwnerEnforced ownership and AES256 server-side encryption.
- Uploaded and downloaded a harmless text file; both copies matched.
- Created Secrets Manager secret secure-ai/day8/demo with a dummy value.
- Retrieved and compared the secret without printing its value.

## Cleanup on 21 October 2026

- Deleted the practice S3 object and bucket.
- Scheduled the practice secret for deletion with a seven-day recovery window.
- The recovery window ends on 28 October 2026.
- Kept the IAM configuration and CLI profile for subsequent exercises.

## Resume CLI access

Refresh the temporary session when needed:

    aws login --profile secure-ai-dev --region ap-south-1 --remote

Ignore any leftover emulator endpoint configuration:

    export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true

Verify the selected identity:

    aws sts get-caller-identity --profile secure-ai-dev --region ap-south-1

The returned ARN should identify user/secure-api.

## Project progress

Jenkins and JFrog provide the existing local build and promotion workflow.
Day 8 established AWS access and verified S3 and Secrets Manager operations.
Application deployment and runtime integration with AWS are future work.
