#!/usr/bin/env bash
# Run a non-secret local Bash script on the existing development EC2 instance.
set -euo pipefail

export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true
export AWS_PAGER=""

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${AWS_PROFILE:-secure-ai-terraform}"
region="ap-south-1"

if [ "$#" -ne 1 ] || [ ! -s "$1" ]; then
    echo "Usage: $0 PATH_TO_NON_SECRET_BASH_SCRIPT" >&2
    exit 64
fi

bash -n "$1"

aws_cli() {
    aws --profile "$profile" --region "$region" --no-cli-pager "$@"
}

account="$(aws_cli sts get-caller-identity --query Account --output text)"
if [ "$account" != "884596874125" ]; then
    echo "STOP: unexpected AWS account." >&2
    exit 1
fi

instance_id="$(
    terraform -chdir="$repo_root/infra/terraform/environments/dev" \
        output -raw instance_id
)"

# The operator permission is intentionally scoped to this specific instance.
if [ "$instance_id" != "i-06351ac1f906a192d" ]; then
    echo "STOP: instance differs from the approved Day 13 target." >&2
    exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# JSON encoding preserves quotes and newlines.
# The generated delimiter is absent from the submitted script.
delimiter="SSM_SCRIPT_$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
while grep -Fxq "$delimiter" "$1"; do
    delimiter="${delimiter}_END"
done

jq -n --rawfile script "$1" --arg delimiter "$delimiter" \
    '{
      commands: [
        ("bash <<'\''" + $delimiter + "'\''\n"
         + $script + "\n" + $delimiter + "\n")
      ],
      executionTimeout: ["600"]
    }' > "$work_dir/request.json"

command_id="$(
    aws_cli ssm send-command \
        --instance-ids "$instance_id" \
        --document-name AWS-RunShellScript \
        --comment "Secure AI development remote script" \
        --parameters "file://$work_dir/request.json" \
        --query 'Command.CommandId' \
        --output text
)"

echo "Instance ID: $instance_id"
echo "Command ID: $command_id"

deadline=$((SECONDS + 900))

while (( SECONDS < deadline )); do
    if ! aws_cli ssm get-command-invocation \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        > "$work_dir/result.json" 2> "$work_dir/error.txt"; then

        # A new invocation can take a short time to become visible.
        if grep -Fq 'InvocationDoesNotExist' "$work_dir/error.txt"; then
            sleep 5
            continue
        fi

        cat "$work_dir/error.txt" >&2
        echo "STOP: could not retrieve the result; remote execution may continue." >&2
        exit 1
    fi

    status="$(jq -r '.Status' "$work_dir/result.json")"

    case "$status" in
        Pending|InProgress|Delayed|Cancelling)
            sleep 5
            ;;
        *)
            jq '{
              Status,
              ExitCode: .ResponseCode,
              Output: .StandardOutputContent,
              Errors: .StandardErrorContent
            }' "$work_dir/result.json"

            if jq -e '.Status == "Success" and .ResponseCode == 0' \
                "$work_dir/result.json" >/dev/null; then
                exit 0
            fi

            echo "FAIL: remote script did not complete successfully." >&2
            exit 1
            ;;
    esac
done

echo "FAIL: local waiting deadline exceeded. Remote execution may continue." >&2
echo "Inspect command: $command_id" >&2
exit 1
