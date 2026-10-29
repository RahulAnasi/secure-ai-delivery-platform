#!/usr/bin/env bash
# Package the approved development deployment and submit it through SSM.
set -euo pipefail

if [ "$#" -eq 0 ]; then
    deployment_mode="deploy"
elif [ "$#" -eq 1 ] && [ "$1" = "--simulate-start-failure" ]; then
    deployment_mode="simulate-start-failure"
    echo "TEST MODE: candidate startup will fail to exercise rollback."
else
    echo "Usage: $0 [--simulate-start-failure]" >&2
    exit 64
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

python3 - "$repo_root" "$work_dir/remote-deployment.sh" "$deployment_mode" <<'PY'
import base64
import io
import tarfile
import textwrap
import sys
from pathlib import Path

root = Path(sys.argv[1])
destination = Path(sys.argv[2])
deployment = root / "deploy/aws/dev"

# Explicit allowlist: never package an entire workspace or secret directory.
names = (
    "artifact.json",
    "configure-model-api-service.sh",
    "verify-runtime.sh",
    "deploy-on-host.sh",
)

buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
    for name in names:
        content = (deployment / name).read_bytes()
        entry = tarfile.TarInfo(name)
        entry.size = len(content)
        entry.mode = 0o600
        archive.addfile(entry, io.BytesIO(content))

encoded = "\n".join(textwrap.wrap(
    base64.b64encode(buffer.getvalue()).decode("ascii"), 76
))

remote = """#!/usr/bin/env bash
set -euo pipefail
umask 077

test "$(id -u)" = "0"

# Use the EC2 instance role, not profile files or inherited access keys.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_CONFIG_FILE=/dev/null
export AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true
export AWS_DEFAULT_REGION=ap-south-1
export AWS_PAGER=""

package_dir="$(mktemp -d /var/tmp/secure-ai-deployment.XXXXXX)"
trap 'rm -rf "$package_dir"' EXIT

base64 --decode <<'DAY13_PACKAGE' |
"""
# Keep the pipeline on one line so Bash parses it correctly.
remote = remote.rstrip() + ' tar -xz -C "$package_dir"\n'
remote += encoded + "\nDAY13_PACKAGE\n"
remote += '\nbash "$package_dir/deploy-on-host.sh" "$package_dir"'
remote += " --simulate-start-failure" if sys.argv[3] == "simulate-start-failure" else ""
remote += "\n"

# Leave room for the command runner's surrounding Bash instructions.
if len(remote.encode("utf-8")) > 24000:
    raise SystemExit("STOP: deployment package exceeds our inline size limit.")

destination.write_text(remote)
print("PASS: packaged four deployment files.")
print(f"Remote script size: {len(remote.encode('utf-8'))} bytes")
PY

bash -n "$work_dir/remote-deployment.sh"

"$repo_root/scripts/run-dev-ssm-script.sh" \
    "$work_dir/remote-deployment.sh"
