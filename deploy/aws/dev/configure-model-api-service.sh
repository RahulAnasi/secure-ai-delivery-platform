sudo bash <<'DAY11_SETUP'
set -euo pipefail

# Verify the operating system and AWS identity before changing files.
. /etc/os-release
test "$ID" = "amzn"
test "$VERSION_ID" = "2023"

role_arn="$(
    aws sts get-caller-identity \
      --region ap-south-1 \
      --query Arn \
      --output text
)"

case "$role_arn" in
    arn:aws:sts::884596874125:assumed-role/secure-ai-dev-ec2-role/*)
        ;;
    *)
        echo "STOP: expected the development EC2 role."
        exit 1
        ;;
esac

install -d -m 0755 /usr/local/libexec

cat > /usr/local/libexec/secure-model-api-run <<'RUNTIME'
#!/bin/bash
set +x
set -euo pipefail
umask 077

image_id="sha256:f4ad4cbaca59d27820e44f49c0836f0395b337290bb45878df52bee423da1b75"
key_file="/run/secure-model-api/model-key"

# Fail rather than write the runtime key onto a disk filesystem.
test "$(stat -f -c %T /run/secure-model-api)" = "tmpfs"

test "$(
    docker image inspect --format '{{.Config.User}}' "$image_id"
)" = "10001:10001"

aws --region ap-south-1 \
    --no-cli-pager \
    secretsmanager get-secret-value \
    --secret-id secure-ai/day9/model-key \
    --query SecretString \
    --output text > "$key_file"

test -s "$key_file"
chown 10001:10001 "$key_file"
chmod 0600 "$key_file"

exec docker run --rm --init \
    --name secure-model-api \
    --pull never \
    --user 10001:10001 \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --memory 256m \
    --cpus 1 \
    --pids-limit 100 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777 \
    --tmpfs /dev/shm:rw,noexec,nosuid,nodev,size=16m,mode=0700,uid=10001,gid=10001 \
    --mount "type=bind,src=$key_file,dst=/run/secrets/model-key,readonly" \
    --env APP_ENV=dev \
    --publish 127.0.0.1:8000:8000 \
    --log-driver local \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    "$image_id"
RUNTIME

chmod 0755 /usr/local/libexec/secure-model-api-run

cat > /etc/systemd/system/secure-model-api.service <<'UNIT'
[Unit]
Description=Secure Model API with AWS-backed runtime key
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
UMask=0077

Environment=AWS_DEFAULT_REGION=ap-south-1
Environment=AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true
Environment=AWS_CONFIG_FILE=/dev/null
Environment=AWS_SHARED_CREDENTIALS_FILE=/dev/null
Environment=AWS_CLI_AUTO_PROMPT=off
Environment=AWS_PAGER=

RuntimeDirectory=secure-model-api
RuntimeDirectoryMode=0700

ExecStartPre=-/usr/bin/docker rm -f secure-model-api
ExecStart=/usr/local/libexec/secure-model-api-run
ExecStop=-/usr/bin/docker stop --time 10 secure-model-api
ExecStopPost=-/usr/bin/docker rm -f secure-model-api
ExecStopPost=/usr/bin/rm -f /run/secure-model-api/model-key

Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

bash -n /usr/local/libexec/secure-model-api-run
systemd-analyze verify /etc/systemd/system/secure-model-api.service
systemctl daemon-reload

echo "PASS: runtime script and service configuration validated."
echo "Service is configured but has not been started."
DAY11_SETUP