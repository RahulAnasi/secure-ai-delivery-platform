Day 12 — Verify EC2 startup recovery
Date: 27 October 2026. Region: ap-south-1 (Mumbai).
What we achieved
We started the stopped Day 11 EC2 instance and verified that Docker and the secure model API recovered automatically, without manually starting either service. The API became healthy, reported its model loaded, and passed a reusable runtime-verification script. We recorded the recovery evidence and stopped EC2 again.

Day 11 established deployment and verified a service stop/start cycle. Day 12 tested a full EC2 stop/start cycle. This closed a previously untested recovery gap; it did not introduce a new deployment or rebuild the image.

No Terraform configuration changes, Terraform apply, security-group modifications or Jenkinsfile changes were required. JFrog CI-to-EC2 delivery remains a separate integration task. This guide was prepared before confirmation of the Day 12 commit or merge.
Starting point
Repository: /home/rahul/projects/secure-ai-delivery-platform on WSL.

Local main matched origin/main at 8d70fa8, the Day 11 merge. The tracked deployment files were artifact.json and configure-model-api-service.sh. The instance was stopped and had no public IP. Untracked floci/ files remained outside our work.

The operator profile secure-ai-terraform identified IAM user secure-api. This profile obtains temporary credentials through the secure-ai-dev browser login. If the session expires, refresh it with:
aws login --profile secure-ai-dev --region ap-south-1 --remote
The working branch created for Day 12 was feat/ec2-startup-recovery.
File map
File	Role
deploy/aws/dev/artifact.json	Existing delivery manifest; supplies the expected runtime image ID for the evidence record
deploy/aws/dev/configure-model-api-service.sh	Existing Day 11 host setup; configured the startup behavior tested today
deploy/aws/dev/verify-runtime.sh	New reusable, read-only runtime verification script
docs/aws/day12-recovery-evidence.json	New historical record transcribed from verified terminal results
docs/aws/day12-startup-recovery.md	Suggested repository location for these study notes


The verifier is stored in Git on WSL. During this test its entire contents were pasted into the EC2 session for execution. We did not install a persistent verifier file or schedule a timer on EC2.
1. Inspect before making changes
Commands used from WSL:
git status --short --branch
git log -1 --oneline
git ls-files deploy/aws/dev
These established branch cleanliness and whether the Day 11 merge/files were present. They do not verify cloud health.

aws sts get-caller-identity established the operator identity. terraform -chdir=infra/terraform/environments/dev output -raw instance_id read the existing resource ID from local state. We did not copy a public IP into connection commands.

ec2 describe-instances showed instance i-06351ac1f906a192d was stopped, with PublicIP null. This was expected after Day 11 shutdown.

Local AWS commands set AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true, preventing configured emulator endpoint overrides from being used. Operator commands used secure-ai-terraform explicitly; commands on the host use its instance role.
2. Create an isolated branch
git switch -c feat/ec2-startup-recovery
This created and selected the feature branch without changing AWS. floci/ remained untouched.
3. Start the existing instance
We used ec2 start-instances with the ID read from Terraform state. This started the existing instance rather than creating a replacement. Compute billing resumed.

The command group defined day12_aws() to supply a consistent profile, region and pager setting. This helper existed only inside that shell group.

Two waiters served different purposes:
Command	What it establishes
ec2 wait instance-running	EC2 has entered running state
ec2 wait instance-status-ok	EC2 system and instance health checks pass
ssm describe-instance-information	Shows whether the agent has connected to Systems Manager


Neither EC2 health checks nor SSM Online establishes application health. They establish that the server is ready to inspect.

Observed results: the same instance ID, running state, a newly assigned public IP and SSM Online. LaunchTime was 2026-10-27T12:47:54Z. The old address was not reused as an identity or security assumption.

Automatic public IPv4 addresses can change after stop/start. Session Manager targets the instance ID, so we did not need a new SSH configuration or an inbound rule.
4. Connect and preserve the recovery evidence
From WSL, we used:
aws --profile secure-ai-terraform --region ap-south-1 \
  --no-cli-pager ssm start-session \
  --target INSTANCE_ID \
  --document-name AWS-StartInteractiveCommand \
  --parameters '{"command":["/bin/bash"]}'
The local Session Manager plugin opens the connection; the SSM agent runs on EC2. The operator IAM policy authorizes the session. The EC2 role supplies the host's AWS permissions, while ssm-user is the Linux account used for the shell.

We deliberately did not run systemctl start/restart for Docker or the application before inspecting them. Doing so would have repaired the state and invalidated the claim of automatic recovery.

When the terminal session was closed, reconnecting opened another shell without restarting the host or its services. Closing a terminal is not the same as stopping EC2.
5. Inspect the current boot
Command	Purpose
uptime -s	Report the current boot start time
cat /proc/sys/kernel/random/boot_id	Identify this boot uniquely
systemctl is-enabled SERVICE	Check startup enablement
systemctl is-active SERVICE	Check current activity
systemctl show ... ActiveEnterTimestamp,NRestarts,Result	Inspect service startup evidence and restart count
docker ps -a --filter name=secure-model-api	Show the existing container and health status
curl --fail ... /health and /ready	Check live HTTP behavior
journalctl -b -u secure-model-api.service	Inspect this boot's application logs


journalctl -b matters: old successful logs cannot establish that this boot recovered. active and enabled also mean different things. A service can be running but disabled, or enabled but failed. We checked both and separately tested HTTP readiness.
Recorded boot evidence
Observation	Result
Instance	i-06351ac1f906a192d, unchanged
Boot start from uptime	2026-10-27 12:47:58 UTC
Boot ID	f662afe5-535b-4cf0-81c1-d33a507d8429
Docker	enabled, active
Application service	enabled, active
Service active timestamp	2026-10-27 12:48:06 UTC
Service result	success
Service restarts	0
Model-ready log	2026-10-27 12:48:09.475 UTC
Application container	running and healthy
Published port	127.0.0.1:8000 only
/health	healthy
/ready	ready; model_loaded true
Manual service start required	no


The model-ready log described sentiment-linear version 1.0.0, followed by application startup completion. The timestamps show prompt recovery in this observation, but we did not define or benchmark a general recovery-time SLA.

For local reading, 12:48:06 UTC corresponds to 18:18:06 IST.
Why recovery worked
Day 11 enabled Docker and the application service at boot. The application unit has network-online ordering and requires Docker. Its launcher uses the loaded image already retained on the root disk.

The host's /run temporary files do not survive an EC2 stop/start. The startup launcher therefore retrieves the key anew from Secrets Manager through the instance role, writes it into its protected runtime directory, and launches the container with the key mounted read-only. Readiness establishes that model initialization succeeded.

The observed recovery is consistent with that configuration and the current-boot logs. We did not capture a CloudTrail GetSecretValue event during this test or inspect the secret value; we do not claim a separate API audit trail was verified.
6. Build a reusable verification script
The script combines Bash with embedded Python. The Bash wrapper uses a subshell so its shell options do not leak into the interactive session. It passes an expected image ID to sudo python3 through an argument. That ID is metadata, not a secret.

Python uses subprocess to inspect systemd/Docker and perform read-only id/stat commands inside the container. It uses urllib to request the loopback API and parses JSON responses. It checks file metadata without printing file contents.

Its require() function prints PASS for a successful condition and raises an error on failure. The outer handler prints FAIL and exits with status 1. It does not restart services, rewrite permissions or repair a deployment. A nonzero result is a signal to investigate.

The default expected configuration ID is:
sha256:f4ad4cbaca59d27820e44f49c0836f0395b337290bb45878df52bee423da1b75
When executed as a file on EC2, another approved ID can be supplied explicitly:
bash verify-runtime.sh sha256:APPROVED_CONFIGURATION_DIGEST
The example placeholder must be replaced by a full real digest. Do not use the source WSL image-store ID as an interchangeable identifier: Day 11 demonstrated that these stores exposed different ID types.

The script's default is not automatically refreshed from artifact.json. If the approved artifact changes, pass its runtime configuration ID explicitly or update the default under review. Do not change an expected value merely to make a failing check pass.
Verifier checks and results
Category	Required condition; observed result
Host	Amazon Linux 2023; PASS
Services	Docker and application enabled/active; PASS
Container	running and Docker health healthy; PASS
Image	expected runtime configuration ID; PASS
Identity	configured user 10001:10001 and actual exec UID 10001; PASS
Root filesystem	read-only; PASS
Capabilities	ALL dropped; PASS
Privilege setting	no-new-privileges configured; PASS
Memory	256 MiB limit; PASS
CPU	one CPU quota; PASS
Processes	100-process limit; PASS
Port binding	exact loopback port 8000 mapping; PASS
Key mount	expected host file mounted read-only; PASS
Key file	regular, nonempty, 600, UID/GID 10001; PASS
Runtime directory	root-owned, mode 0700; PASS
Key filesystem	tmpfs; PASS
Model file	600, UID/GID 10001, tmpfs; PASS
HTTP routes	200 and expected status values; PASS
Model readiness	model_loaded true; PASS


The script also prints boot ID, ActiveEnterTimestamp, NRestarts and Result. It reports restart count; it does not enforce zero as a separate code gate. Automatic startup was established by the recovery procedure and boot evidence, not by a script proving that nobody had manually started a service.

The script fails immediately on the first failed condition. It does not wait for a warming-up application to become healthy. Running it too early can fail a health check; inspect startup and retry after readiness rather than treating it as an auto-healing tool.

The script's shell and embedded Python syntax were checked before delivery. Its positive path was executed on EC2 and all checks passed. We did not deliberately break production settings or execute a negative-path acceptance test today. We did not test propagation of remote exit status through a Jenkins job or Session Manager wrapper; no CI integration was added.
7. Record evidence separately from configuration
A local Python command read artifact.json and wrote docs/aws/day12-recovery-evidence.json. It records the observed boot ID, active timestamp, instance ID, expected runtime ID, zero restarts and successful API/verifier results.

The record explicitly identifies its source as verified Session Manager output. It was transcribed from our observations, not automatically captured by the verifier, digitally signed or continuously updated.

This is a historical test record. A PASS stored in Git is not proof that the server is healthy now. For current status, rerun live checks on the running host.
8. Stop the server after testing
We exited the remote shell, then used WSL to resolve the instance ID from Terraform outputs, call ec2 stop-instances and wait with ec2 wait instance-stopped. The final AWS query returned stopped.

Compute stopped, while EBS, S3 artifact storage and the Secrets Manager secret remained retained/billable. The root disk retains Docker, the loaded image and service definitions. The automatic public IP is released. Nothing was destroyed or rebuilt.

No Terraform plan/apply was necessary because we did not change Terraform configuration. Local outputs can retain an earlier public-IP value until refreshed. Day 11 showed that a stopped instance can also produce a public-IP-association replacement proposal in the provider: inspect fresh plans carefully and do not apply an unexpected replacement.
How to repeat the test
1. From WSL, verify the operator identity and existing stopped instance ID.
2. Start that instance; wait for running/EC2 checks and SSM Online.
3. Connect through Session Manager without starting/restarting Docker or the API manually.
4. Inspect this boot's service state and application logs.
5. Run the verifier on EC2 with the approved runtime ID.
6. Record the actual results, not an assumed PASS.
7. Stop the instance when finished, or deliberately keep it running for subsequent authorized work.
The verifier expects the existing deployment. It is not a deployment installer and should not be run as a host check on WSL. Use bash -n deploy/aws/dev/verify-runtime.sh on WSL for syntax checking only.
Troubleshooting boundaries
If Docker is inactive, inspect its current-boot journal before repairing it. If the application is inactive or failed, inspect its journal, dependency ordering, role permissions and network connectivity. If the image ID differs, establish the intended artifact rather than weakening the gate. If the API fails while the service is active, inspect readiness/model startup: systemd Type=simple does not guarantee HTTP readiness.

If key/model permissions or tmpfs checks fail, investigate the actual startup/mount configuration without printing key contents. Preserve the first failure output. A later manual restart may restore service but should be documented as a recovery intervention, not automatic recovery success.

A script PASS is scoped to its checks. This is not a CVE scan, secret-exposure audit, authorization penetration test, encryption-key rotation test, disaster recovery from lost EBS or a multi-AZ failover exercise.
Git handoff
The expected Day 12 commit contains three new files: verify-runtime.sh, day12-recovery-evidence.json and day12-startup-recovery.md. Leave floci/ untouched. Keep state, saved plans, archives and key values out of Git.

Validate shell and evidence JSON, run git diff --check, stage explicit paths and inspect the staged diff. No Day 12 commit/merge is claimed in these notes until separately confirmed.
Mental model
Configuration enables recovery; observation proves it. EBS preserves the application image and service definitions. The new boot recreates temporary runtime state. The instance role authorizes retrieving the key again. systemd coordinates startup, Docker enforces the container settings and application readiness confirms successful model loading.

The verifier makes these expectations repeatable. The evidence file records what happened in this one test. Neither replaces the other.
Recruiter explanation
I validated full EC2 stop/start recovery for a systemd-managed secure model API. Docker and the application started automatically, fetched the runtime key through the instance role and became ready without manual intervention. I added a reusable verifier covering image identity, application health, non-root execution, resource limits, loopback binding and tmpfs-backed key/model protection, recorded the boot evidence and stopped compute after testing.