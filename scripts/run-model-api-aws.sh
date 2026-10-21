#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true

day9_aws() {
    aws --profile secure-ai-dev --region ap-south-1 --no-cli-pager "$@"
}

day9_uid="$(id -u)"
day9_gid="$(id -g)"

if [ "$day9_uid" -eq 0 ]; then
    echo "ERROR: run this script as your normal WSL user."
    exit 1
fi

if [ "$(stat -f -c %T /dev/shm)" != "tmpfs" ]; then
    echo "ERROR: /dev/shm must be a tmpfs filesystem."
    exit 1
fi

day9_image_id="$(docker image inspect --format '{{.Id}}' secure-model-api:dev-local)"
day9_identity="$(day9_aws sts get-caller-identity --query Arn --output text)"

if [ "$day9_identity" != "arn:aws:iam::884596874125:user/secure-api" ]; then
    echo "ERROR: expected the secure-api IAM user."
    exit 1
fi

day9_directory="$(mktemp -d /dev/shm/secure-ai-day9.XXXXXX)"

cleanup() {
    day9_exit_status=$?
    trap - EXIT
    if [ -s "$day9_directory/container.cid" ]; then
        docker rm -f "$(cat "$day9_directory/container.cid")" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$day9_directory"
    exit "$day9_exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

day9_aws secretsmanager get-secret-value \
    --secret-id secure-ai/day9/model-key \
    --query SecretString --output text > "$day9_directory/model-key"

test -s "$day9_directory/model-key"

echo "Runtime key retrieved from AWS Secrets Manager."
echo "Starting image: $day9_image_id"
echo "Leave this terminal open. Press Ctrl+C to stop the API."

docker run --rm --init \
    --name secure-model-api-aws-local \
    --cidfile "$day9_directory/container.cid" \
    --pull=never \
    --user "$day9_uid:$day9_gid" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777 \
    --tmpfs "/dev/shm:rw,noexec,nosuid,nodev,size=16m,mode=0700,uid=$day9_uid,gid=$day9_gid" \
    --mount "type=bind,src=$day9_directory/model-key,dst=/run/secrets/model-key,readonly" \
    --env APP_ENV=dev \
    --publish 127.0.0.1:8000:8000 \
    --memory 256m --cpus 1 --pids-limit 100 \
    "$day9_image_id"
