#!/usr/bin/env bash
# Run on EC2 with a directory containing the approved deployment files.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 DEPLOYMENT_PACKAGE_DIRECTORY [--simulate-start-failure]" >&2
    exit 64
fi

# Serialize deployments on this host. The lock is released when this process exits.
exec 9>/run/lock/secure-model-api-deploy.lock
flock -n 9 || { echo "STOP: another deployment holds the lock." >&2; exit 1; }

python3 - "$@" <<'PY'
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
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

SERVICE = "secure-model-api.service"
LAUNCHER = Path("/usr/local/libexec/secure-model-api-run")
UNIT = Path("/etc/systemd/system/secure-model-api.service")
snapshot = None
previous_image = None
mutation_started = False

def wait_for_health():
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        probe = subprocess.run(
            ["docker", "inspect", "--format",
             "{{if .State.Health}}{{.State.Health.Status}}{{end}}",
             "secure-model-api"], text=True, capture_output=True,
        )
        if probe.returncode == 0 and probe.stdout.strip() == "healthy":
            return
        if output("systemctl", "show", SERVICE, "--property=ActiveState", "--value") == "failed":
            raise RuntimeError("application service entered failed state")
        time.sleep(2)
    raise RuntimeError("application did not become healthy within two minutes")

def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def restore_file(source, destination):
    # The preflight below requires root-owned regular files.
    temporary = destination.with_name(destination.name + ".rollback-tmp")
    try:
        shutil.copy2(source, temporary)
        os.chown(temporary, 0, 0)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)

try:
    require(os.geteuid() == 0, "deployment runs as root")
    require(len(sys.argv) == 2 or sys.argv[2] == "--simulate-start-failure",
            "supported deployment mode")
    simulate_failure = len(sys.argv) == 3

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

    # Refuse to replace an unhealthy deployment: rollback needs a verified baseline.
    require(output("systemctl", "show", SERVICE, "--property=FragmentPath", "--value")
            == str(UNIT), "expected systemd unit file")
    require(output("systemctl", "show", SERVICE, "--property=DropInPaths", "--value")
            == "", "no unsupported systemd drop-in overrides")
    for path in (LAUNCHER, UNIT):
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == info.st_gid == 0,
                "root-owned regular rollback file: " + path.name)
    previous_image = output("docker", "inspect", "--format", "{{.Image}}",
                            "secure-model-api")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", previous_image) is not None,
            "valid previous runtime image ID")
    require('image_id="' + previous_image + '"' in LAUNCHER.read_text(),
            "installed launcher matches running image")
    run("bash", str(verifier), previous_image)
    print("PASS: existing deployment is a verified rollback baseline.", flush=True)

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

    # Save only non-secret configuration. Never copy /run or the model key.
    rollback_root = Path("/opt/secure-model-api/rollback")
    rollback_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(rollback_root.lstat().st_uid == 0 and not rollback_root.is_symlink(),
            "root-owned rollback directory")
    rollback_root.chmod(0o700)
    snapshot = Path(tempfile.mkdtemp(prefix="deployment-", dir=rollback_root))
    shutil.copy2(LAUNCHER, snapshot / "launcher")
    shutil.copy2(UNIT, snapshot / "service")
    shutil.copy2(verifier, snapshot / "verify-runtime.sh")
    record = {
        "previous_image_id": previous_image,
        "candidate_image_id": expected_image,
        "launcher_sha256": file_hash(LAUNCHER),
        "service_sha256": file_hash(UNIT),
        "status": "baseline-saved",
    }
    def save_record(status):
        record["status"] = status
        (snapshot / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    save_record("baseline-saved")
    print("Rollback snapshot:", snapshot, flush=True)

    print("Configuring and restarting application service.", flush=True)
    mutation_started = True
    run("bash", str(setup))
    if simulate_failure:
        # An explicit lab mode: fail before fetching a secret or starting Docker.
        LAUNCHER.write_text("#!/bin/bash\necho 'Intentional Day 14 startup failure.' >&2\nexit 23\n")
        LAUNCHER.chmod(0o755)
        print("TEST: installed deliberately failing candidate launcher.", flush=True)
    run("systemctl", "enable", "docker.service")
    run("systemctl", "enable", "secure-model-api.service")
    run("systemctl", "reset-failed", SERVICE)
    run("systemctl", "restart", "secure-model-api.service")
    wait_for_health()
    run("bash", str(verifier), expected_image)
    save_record("deployment-succeeded")
    print("PASS: deployment and runtime verification completed.", flush=True)

except Exception as error:
    print(f"FAIL: deployment stopped: {error}", file=sys.stderr)
    if mutation_started:
        try:
            print("ROLLBACK: restoring the verified previous deployment.", flush=True)
            run("systemctl", "stop", SERVICE)
            restore_file(snapshot / "launcher", LAUNCHER)
            restore_file(snapshot / "service", UNIT)
            require(file_hash(LAUNCHER) == record["launcher_sha256"],
                    "restored launcher checksum")
            require(file_hash(UNIT) == record["service_sha256"],
                    "restored service checksum")
            run("systemctl", "daemon-reload")
            run("systemctl", "reset-failed", SERVICE)
            run("systemctl", "start", SERVICE)
            wait_for_health()
            run("bash", str(snapshot / "verify-runtime.sh"), previous_image)
            save_record("deployment-failed-rollback-succeeded")
            print("PASS: previous deployment restored and verified.", flush=True)
            print("FAIL: attempted deployment remains failed despite successful rollback.",
                  file=sys.stderr)
        except Exception as rollback_error:
            print(f"CRITICAL: rollback failed: {rollback_error}", file=sys.stderr)
            if snapshot is not None:
                print("Recovery snapshot:", snapshot, file=sys.stderr)
            raise SystemExit(2)
    else:
        print("Existing service configuration was not changed.", file=sys.stderr)
    raise SystemExit(1)
PY
