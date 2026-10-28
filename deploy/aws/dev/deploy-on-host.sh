#!/usr/bin/env bash
# Run on EC2 with a directory containing the approved deployment files.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 DEPLOYMENT_PACKAGE_DIRECTORY" >&2
    exit 64
fi

python3 - "$1" <<'PY'
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import time
from pathlib import Path

def run(*args):
    subprocess.run(args, check=True)

def output(*args):
    return subprocess.check_output(args, text=True).strip()

def require(condition, message):
    if not condition:
        raise RuntimeError(message)
    print("PASS:", message, flush=True)

try:
    require(os.geteuid() == 0, "deployment runs as root")

    package = Path(sys.argv[1]).resolve()
    manifest = json.loads((package / "artifact.json").read_text())

    setup = package / "configure-model-api-service.sh"
    verifier = package / "verify-runtime.sh"
    require(setup.is_file() and verifier.is_file(), "deployment scripts present")
    run("bash", "-n", str(setup))
    run("bash", "-n", str(verifier))

    # This deployment uses the existing Day 11 image/key pair.
    # The existing service setup script is pinned to this configuration ID.
    expected_image = (
        "sha256:f4ad4cbaca59d27820e44f49c0836f0395"
        "b337290bb45878df52bee423da1b75"
    )
    require(manifest["schema_version"] == 1, "supported manifest schema")
    require(manifest["runtime_image_id"] == expected_image,
            "manifest matches the supported service image")
    require(manifest["runtime_platform"] == "linux/amd64",
            "approved runtime platform")
    require(manifest["aws_region"] == "ap-south-1", "approved AWS region")
    require(manifest["runtime_secret_id"] == "secure-ai/day9/model-key",
            "approved runtime secret reference")
    require(manifest["archive_name"] == "secure-model-api.tar.gz",
            "approved archive filename")
    require(re.fullmatch(r"[0-9a-f]{64}", manifest["archive_sha256"]) is not None,
            "valid archive checksum")
    require(type(manifest["archive_bytes"]) is int
            and manifest["archive_bytes"] > 0, "valid archive size")

    aws = [
        "aws", "--region", "ap-south-1", "--no-cli-pager",
        "--cli-connect-timeout", "10", "--cli-read-timeout", "60",
    ]
    role = output(*aws, "sts", "get-caller-identity",
                  "--query", "Arn", "--output", "text")
    require(role.startswith(
        "arn:aws:sts::884596874125:assumed-role/secure-ai-dev-ec2-role/"
    ), "expected EC2 runtime role")

    bucket = "secure-ai-delivery-884596874125-ap-south-1-dev"
    object_key = (
        f'artifacts/{manifest["archive_sha256"]}/{manifest["archive_name"]}'
    )
    artifact_dir = Path("/opt/secure-model-api/artifacts")
    artifact_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    archive = artifact_dir / manifest["archive_name"]
    download = artifact_dir / (manifest["archive_name"] + ".download")

    try:
        print("Downloading approved S3 artifact.", flush=True)
        run(*aws, "s3api", "get-object",
            "--bucket", bucket,
            "--key", object_key,
            "--expected-bucket-owner", "884596874125",
            str(download))

        require(download.stat().st_size == manifest["archive_bytes"],
                "downloaded archive size matches manifest")

        digest = hashlib.sha256()
        with download.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        require(digest.hexdigest() == manifest["archive_sha256"],
                "downloaded archive checksum matches manifest")

        # Read archive metadata without extracting its filesystem.
        with tarfile.open(download, "r:gz") as bundle:
            entries = json.load(bundle.extractfile("manifest.json"))
            require(len(entries) == 1, "archive contains one image")
            config_stream = bundle.extractfile(entries[0]["Config"])
            config_bytes = config_stream.read()
            config = json.loads(config_bytes)

        require("sha256:" + hashlib.sha256(config_bytes).hexdigest()
                == expected_image, "archive configuration matches approved image")
        require(config["os"] == "linux"
                and config["architecture"] == "amd64",
                "archive platform matches target")
        require(config["config"]["User"] == "10001:10001",
                "archive specifies non-root application user")

        download.replace(archive)
    finally:
        download.unlink(missing_ok=True)

    run("docker", "info", "--format", "{{.ServerVersion}}")
    run("docker", "load", "--input", str(archive))

    loaded = json.loads(output("docker", "image", "inspect", expected_image))[0]
    require(loaded["Id"] == expected_image, "loaded image configuration ID")
    require(loaded["RootFS"]["Layers"] == config["rootfs"]["diff_ids"],
            "loaded image layers match archive configuration")

    print("Configuring and restarting application service.", flush=True)
    run("bash", str(setup))
    run("systemctl", "enable", "docker.service")
    run("systemctl", "enable", "secure-model-api.service")
    run("systemctl", "restart", "secure-model-api.service")

    for attempt in range(60):
        probe = subprocess.run(
            ["docker", "inspect", "--format",
             "{{if .State.Health}}{{.State.Health.Status}}{{end}}",
             "secure-model-api"],
            text=True, capture_output=True,
        )
        if probe.returncode == 0 and probe.stdout.strip() == "healthy":
            break
        time.sleep(2)
    else:
        raise RuntimeError("application did not become healthy within two minutes")

    run("bash", str(verifier), expected_image)
    print("PASS: deployment and runtime verification completed.", flush=True)

except Exception as error:
    print(f"FAIL: deployment stopped: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
