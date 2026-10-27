#!/bin/bash
# Run on the Amazon Linux EC2 host. Optional argument: expected Docker config ID.
# This script inspects the deployment; it does not start or repair services.
(
    set -eu

    expected_image="${1:-sha256:f4ad4cbaca59d27820e44f49c0836f0395b337290bb45878df52bee423da1b75}"

    sudo python3 - "$expected_image" <<'PY'
import json
import os
import re
import stat
import subprocess
import sys
import urllib.request
from pathlib import Path

expected_image = sys.argv[1]
if not re.fullmatch(r"sha256:[0-9a-f]{64}", expected_image):
    raise SystemExit("FAIL: expected image must be a full SHA-256 configuration ID.")

def command(*args):
    return subprocess.check_output(args, text=True).strip()

def require(condition, label):
    if not condition:
        raise RuntimeError(label)
    print(f"PASS: {label}", flush=True)

try:
    release = dict(
        line.split("=", 1)
        for line in Path("/etc/os-release").read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )
    require(
        release.get("ID", "").strip('"') == "amzn"
        and release.get("VERSION_ID", "").strip('"') == "2023",
        "expected Amazon Linux 2023 host",
    )
    print("Boot ID:", Path("/proc/sys/kernel/random/boot_id").read_text().strip())

    for service in ("docker.service", "secure-model-api.service"):
        require(command("systemctl", "is-active", service) == "active", f"{service} active")
        require(command("systemctl", "is-enabled", service) == "enabled", f"{service} enabled")

    image = json.loads(command("docker", "inspect", "--type", "container", "secure-model-api"))[0]
    host = image["HostConfig"]
    require(image["State"]["Running"], "application container running")
    require(image["State"].get("Health", {}).get("Status") == "healthy", "Docker health check healthy")
    require(image["Image"] == expected_image, "expected runtime image configuration ID")
    require(image["Config"]["User"] == "10001:10001", "configured application user 10001:10001")
    require(command("docker", "exec", "secure-model-api", "id", "-u") == "10001", "actual application UID 10001")
    require(host["ReadonlyRootfs"] is True, "read-only root filesystem")
    require("ALL" in (host.get("CapDrop") or []), "all Linux capabilities dropped")
    require(any(x.startswith("no-new-privileges") for x in (host.get("SecurityOpt") or [])), "no-new-privileges configured")
    require(host["Memory"] == 256 * 1024 * 1024, "256 MiB memory limit")
    require(host["NanoCpus"] == 1_000_000_000, "one CPU limit")
    require(host["PidsLimit"] == 100, "100-process limit")
    require(host["PortBindings"] == {"8000/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8000"}]}, "API published only on host loopback port 8000")

    key = "/run/secure-model-api/model-key"
    mounts = [m for m in image["Mounts"] if m["Destination"] == "/run/secrets/model-key"]
    require(len(mounts) == 1 and mounts[0]["Type"] == "bind" and mounts[0]["Source"] == key and mounts[0]["RW"] is False, "expected key file mounted read-only")
    info = os.stat(key)
    require(stat.S_ISREG(info.st_mode) and info.st_size > 0, "runtime key file present and nonempty")
    require(stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == info.st_gid == 10001, "key permissions 600 and owner 10001:10001")
    directory = os.stat("/run/secure-model-api")
    require(stat.S_IMODE(directory.st_mode) == 0o700 and directory.st_uid == 0, "root-owned private runtime directory")
    require(command("stat", "-f", "-c", "%T", key) == "tmpfs", "host key stored on tmpfs")
    require(command("docker", "exec", "secure-model-api", "stat", "-c", "%a:%u:%g", "/dev/shm/model.bin") == "600:10001:10001", "decrypted model permissions 600 and owner 10001:10001")
    require(command("docker", "exec", "secure-model-api", "stat", "-f", "-c", "%T", "/dev/shm/model.bin") == "tmpfs", "decrypted model stored on tmpfs")

    for route, expected_status in (("/health", "healthy"), ("/ready", "ready")):
        with urllib.request.urlopen("http://127.0.0.1:8000" + route, timeout=5) as response:
            require(response.status == 200, f"{route} returns HTTP 200")
            body = json.load(response)
        require(body.get("status") == expected_status, f"{route} expected status")
        if route == "/ready":
            require(body.get("model_loaded") is True, "API reports model loaded")

    print(command("systemctl", "show", "secure-model-api.service", "--property=ActiveEnterTimestamp", "--property=NRestarts", "--property=Result"))
    print("PASS: all runtime verification checks passed.")
except Exception as error:
    # Do not print container environments, secret contents or HTTP response bodies.
    print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
)