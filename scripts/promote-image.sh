#!/usr/bin/env bash

set -Eeuo pipefail
set +x

readonly REGISTRY="${JFROG_REGISTRY:-172.18.0.1:8083}"

if [[ "$#" -ne 5 ]]; then
    echo "Usage: $0 SOURCE_REPOSITORY TARGET_REPOSITORY IMAGE_NAME IMAGE_TAG EXPECTED_DIGEST" >&2
    exit 64
fi

readonly SOURCE_REPOSITORY="$1"
readonly TARGET_REPOSITORY="$2"
readonly IMAGE_NAME="$3"
readonly IMAGE_TAG="$4"
readonly EXPECTED_DIGEST="$5"

: "${JFROG_USERNAME:?JFROG_USERNAME is required}"
: "${JFROG_PASSWORD:?JFROG_PASSWORD is required}"

validate_name() {
    local value="$1"
    local field="$2"

    if [[ ! "$value" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
        printf 'ERROR: invalid %s: %s\n' "$field" "$value" >&2
        exit 64
    fi
}

validate_name "$SOURCE_REPOSITORY" "source repository"
validate_name "$TARGET_REPOSITORY" "target repository"
validate_name "$IMAGE_NAME" "image name"

if [[ "$SOURCE_REPOSITORY" == "$TARGET_REPOSITORY" ]]; then
    echo "ERROR: source and target repositories must differ." >&2
    exit 64
fi

if [[ ! "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "ERROR: invalid image tag." >&2
    exit 64
fi

if [[ ! "$EXPECTED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: expected digest must be a SHA-256 digest." >&2
    exit 64
fi

readonly SOURCE_REF="${REGISTRY}/${SOURCE_REPOSITORY}/${IMAGE_NAME}@${EXPECTED_DIGEST}"
readonly TARGET_REF="${REGISTRY}/${TARGET_REPOSITORY}/${IMAGE_NAME}:${IMAGE_TAG}"

cleanup() {
    docker logout "$REGISTRY" >/dev/null 2>&1 || true
}

trap cleanup EXIT

printf '%s' "$JFROG_PASSWORD" |
    docker login "$REGISTRY" \
        --username "$JFROG_USERNAME" \
        --password-stdin

echo "Pulling approved source artifact by digest."
docker pull "$SOURCE_REF"

echo "Promoting the existing artifact without rebuilding."
docker tag "$SOURCE_REF" "$TARGET_REF"
docker push "$TARGET_REF"

ACTUAL_DIGEST="$(
    docker buildx imagetools inspect "$TARGET_REF" |
        awk '$1 == "Digest:" {print $2; found=1; exit}
             END {if (!found) exit 1}'
)"

if [[ "$ACTUAL_DIGEST" != "$EXPECTED_DIGEST" ]]; then
    echo "ERROR: promoted digest does not match the approved source digest." >&2
    printf 'Expected: %s\nActual:   %s\n' \
        "$EXPECTED_DIGEST" \
        "$ACTUAL_DIGEST" >&2
    exit 1
fi

printf 'Published image: %s\n' "$TARGET_REF"
printf 'Published digest: %s\n' "$ACTUAL_DIGEST"
echo "PASS: artifact promoted without rebuilding."