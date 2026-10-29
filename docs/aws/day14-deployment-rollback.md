Day 14 — Automatic EC2 Deployment Rollback
Implementation and live tests: 29 October 2026. These notes were written after EC2 was confirmed stopped; the Day 14 commit and merge were still pending.
Goal
Recover the working application automatically if a deployment breaks its configuration or startup, while still reporting the attempted deployment as failed.

Day 13 could report failure but could not restore service after a failed restart. Day 14 adds a recovery path around the part of deployment that changes the installed launcher and service configuration.

We tested a deliberately failing candidate launcher. The old and candidate deployments used the same approved image. This proves configuration/startup recovery, not a tested rollback between different image versions.
Starting point
- Branch: feat/ec2-deployment-rollback.
- Existing instance: i-06351ac1f906a192d, Mumbai (ap-south-1).
- Operator: IAM user secure-api, through profile secure-ai-terraform.
- Host runtime role: secure-ai-dev-ec2-role.
- Existing application was already deployed, enabled at boot, and verified.
- Terraform, IAM, the artifact manifest, and Jenkinsfiles were not changed on Day 14.
- The original 30-day roadmap remains the coverage checklist. Our actual day numbering has shifted; the original roadmap's secondary IaC tools and other unfinished topics are not completed simply because we reached Day 14.
Files changed
File	Responsibility
deploy/aws/dev/deploy-on-host.sh	Host deployment, baseline validation, configuration backup, automatic recovery, and verification
scripts/deploy-dev-ssm.sh	Local packaging/submission, now with an explicit controlled-failure option


The notes are stored in the repository as docs/aws/day14-deployment-rollback.md.

Reused files:
- scripts/run-dev-ssm-script.sh: sends a non-secret script through SSM and returns local success or failure.
- deploy/aws/dev/artifact.json: approved archive and runtime image identities.
- deploy/aws/dev/configure-model-api-service.sh: writes the candidate launcher and systemd service.
- deploy/aws/dev/verify-runtime.sh: checks image identity, runtime restrictions, secrets handling, and API readiness.
Mental model
A deployment has two broad phases:
1. Preparation: validate inputs, verify the running baseline, download/check the candidate archive, and load the image. A failure here leaves the installed service configuration unchanged.
2. Service changes: install candidate configuration, restart, and verify. A failure here triggers restoration of the saved configuration and verification of the recovered application.
The snapshot is a backup of configuration files and identity metadata, not a VM snapshot, database backup, or copy of runtime secrets.
1. Refresh authentication and inspect the existing implementation
The temporary operator session expired. We refreshed it from WSL:
aws login --profile secure-ai-dev --region ap-south-1 --remote
Then checked STS using secure-ai-terraform. This profile obtains temporary credentials from the login profile. The confirmed ARN ended in user/secure-api.

We inspected the branch, artifact manifest, host deployment script, and service installer before changing code. The previous script verified image bytes before restart, but an exception after configuration changes only returned failure; it had no restoration branch.
2. Add host-level deployment serialization
The Bash wrapper opens /run/lock/secure-model-api-deploy.lock on file descriptor 9 and calls flock -n 9.

This prevents two instances of this deployment script from simultaneously modifying the same application. A competing deployment fails immediately. The lock is held for the lifetime of the deployment process and released when it exits.

This is an application-deployment lock, not Terraform state locking. The lock path is on the host and is not part of the rollback backup.
3. Require a verified rollback baseline
Before changing configuration, deployment requires:
- The expected systemd unit file at /etc/systemd/system/secure-model-api.service.
- No systemd drop-in overrides, because this implementation does not back those up.
- Root-owned regular files for the launcher and unit; symbolic links are rejected by the regular-file check.
- A full SHA-256 ID for the currently running container image.
- The installed launcher's pinned image ID matching the running container.
- The existing runtime verifier passing against that previous image ID.
Why: saving an unhealthy or mismatched baseline would not provide a trustworthy rollback target.

This implementation requires an existing healthy application. It is not a first-install workflow and does not automatically repair an already unhealthy baseline.
4. Continue validating the candidate artifact
The Day 13 checks remain: schema, platform, region, secret reference, archive filename/size/checksum, expected EC2 role, S3 expected owner, archive configuration digest, configured non-root user, loaded image ID, and loaded root filesystem layer identifiers.

Downloads are checked before the installed service configuration changes. Loading an image is preparation; it does not itself replace the running application container.

The deployment is still pinned to the current approved Day 11 image/key pair:
sha256:f4ad4cbaca59d27820e44f49c0836f0395b337290bb45878df52bee423da1b75
The runtime secret reference remains secure-ai/day9/model-key. No secret values are included in the submitted SSM package.
5. Save the rollback snapshot
Before invoking the service installer, deployment creates a private directory:
/opt/secure-model-api/rollback/deployment-<unique-suffix>/
It contains:
Snapshot file	Contents
launcher	Copy of /usr/local/libexec/secure-model-api-run
service	Copy of /etc/systemd/system/secure-model-api.service
verify-runtime.sh	Verifier supplied with this deployment package
result.json	Previous/candidate image IDs, saved configuration hashes, and outcome


The supplied verifier is first used to accept the existing deployment, then retained for recovery verification. It is not a separately retrieved historical verifier from an older release.

The backup includes the launcher’s secret reference, not the model key. It does not copy /run/secure-model-api, /dev/shm/model.bin, or the Secrets Manager value.

The rollback root and each unique snapshot directory are private to root. Configuration permissions are preserved. The previous Docker image remains in the local image store; the backup does not export another image archive.

The script marks mutation_started immediately before running the service installer. This is important: an installer that partially writes files and then fails must also trigger restoration.
6. Attempt deployment and verify acceptance
The normal path configures the candidate service, enables the services, clears systemd failure/start-limit state, and restarts the application.

It waits for Docker health, fails early if the systemd service reaches failed, and then runs the full verifier. A healthy Docker status alone is insufficient: the verifier also checks identity, restrictions, secret permissions/storage, and HTTP readiness.

On success, the snapshot record status becomes deployment-succeeded and the command returns exit code 0.

The installer may print “Service is configured but has not been started.” This refers to the installer itself. The surrounding deployment script subsequently starts/restarts it.
7. Restore automatically after a deployment failure
If an exception occurs after service mutation begins, the recovery path:
1. Stops the candidate service.
2. Restores the saved launcher and unit through temporary files and atomic path replacement.
3. Verifies both restored SHA-256 hashes against the saved values.
4. Runs systemctl daemon-reload to load the restored unit definition.
5. Runs systemctl reset-failed to clear failed/start-limit state.
6. Starts the restored service.
7. Waits for health and runs the saved verifier against the previous image ID.
8. Records deployment-failed-rollback-succeeded and reports that recovery succeeded.
9. Exits with code 1, because the attempted deployment failed.
If recovery itself fails, the host script prints CRITICAL, retains the snapshot path for investigation, and exits 2.

reset-failed also resets the service restart counter. Therefore, NRestarts=0 after recovery is not evidence that the candidate never failed. The SSM failure output, recovery messages, and restored configuration hashes supply that evidence.
8. Add an explicit controlled-failure option
Normal deployment from WSL:
./scripts/deploy-dev-ssm.sh
Controlled startup failure:
./scripts/deploy-dev-ssm.sh --simulate-start-failure
The local wrapper validates its arguments and passes the explicit test option to the host script. Unsupported arguments exit 64 locally.

In test mode, after saving the baseline and installing candidate configuration, the host script writes a candidate launcher that prints an intentional failure message and exits 23. This occurs before retrieving any model secret or starting the candidate container.

This creates a genuine service-start failure. It is not simply a fabricated return code after a healthy deployment. The test briefly interrupts the single-instance application while restoration occurs.
9. Fix a truncated local file before cloud testing
The first edited local file was incomplete. Bash reported a missing heredoc terminator and embedded Python reported an unclosed parenthesis. Adding a closing PY would not have restored the missing deployment code.

We downloaded the complete script, found it in the Windows Downloads directory, normalized CRLF line endings, and copied it into the repository only after its SHA-256 matched the verified source.

The complete delivered host script had 262 lines and 11,343 bytes, with SHA-256:
ddc52dbb282ac5528da60ccc2aee6dd8f3c3699295461b4badd8e6cd4039a862
We then checked Bash syntax, compiled the embedded Python without executing it, and checked whitespace. That checksum identifies the delivered version at this point; later legitimate edits would change it.

Locally, before EC2 testing, temporary-file/mocked-command simulations covered normal success, candidate startup failure, partial installer failure, and recovery failure. These simulations were not live EC2 tests.
10. Live normal deployment test
We started the same EC2 instance, waited for running state and both EC2 status checks, and confirmed Systems Manager Online.

Command ID:
2f54beba-2ce4-48dc-a2df-327b60a0284c
Observed outcome: SSM Success, exit code 0. The baseline verifier passed, image integrity checks passed, and the deployed application passed the full verifier.

Snapshot:
/opt/secure-model-api/rollback/deployment-7810x2pa
Boot ID: 119afa72-d8e4-40ef-9afd-c9cd5f2329df.

After normal deployment, service active timestamp: 2026-10-29T04:53:34Z.
11. Live controlled startup failure and recovery
Command ID:
250cc4e8-5691-47fa-95fe-86790d131c23
Snapshot:
/opt/secure-model-api/rollback/deployment-j7kmib30
Observed sequence:
- Healthy baseline accepted and saved.
- Deliberately failing candidate launcher installed.
- Candidate service entered failed state.
- Automatic restoration ran.
- Restored launcher and service checksums passed.
- Application restarted and all runtime checks passed.
- Output confirmed “previous deployment restored and verified.”
After recovery, service active timestamp: 2026-10-29T04:56:34Z.
Layer	Observed result
Candidate launcher	Deliberately exits 23
Host deployment script	Exits 1 after successful recovery
SSM command	Failed, response code 1
Local command runner	Exits 1
Recovered application	Healthy, ready, model loaded; security checks passed


The wrapper’s “remote script did not complete successfully” is expected. It reports the failed deployment attempt; it does not mean the verified rollback failed.

The unrelated acpid.socket legacy /var/run warning remained non-fatal. We did not modify that operating-system unit.

The snapshot result record is written by the implementation; during this lab we verified live command output and restored hashes, but did not separately retrieve result.json afterward.
12. Important boundaries
- Tested: automatic recovery from a broken launcher using the same approved image and secret reference.
- Not yet tested: moving between two different application image versions or secret versions.
- No model key backup or version pinning was added. Restoring a secret reference assumes that the referenced secret can still decrypt the previous image. Secret rotation needs its own compatibility/retention design.
- The script does not roll back database changes, S3 objects, Terraform resources, or external side effects.
- The new baseline checks reject unsupported drop-in overrides and unhealthy existing deployments.
- Host recovery failure was simulated locally but not deliberately induced on EC2.
- Lock contention was not live-tested. Snapshots accumulate; automatic retention was not added.
- Catching Python exceptions does not guarantee recovery after process termination, SSM timeout, host shutdown, SIGKILL, or power loss. Persistent snapshots assist manual recovery but do not provide a crash-resumable deployment transaction.
- The local command runner maps any unsuccessful SSM invocation to local exit 1. Inspect the remote response to distinguish host exit 1 from host exit 2.
- Jenkins integration remains future work. JFrog artifact promotion from Day 7 is distinct from restoring a running EC2 service.
13. Final state and cleanup
We stopped EC2 using ec2 stop-instances, waited with ec2 wait instance-stopped, and confirmed state stopped.

Final whitespace checks passed. Only the host deployment script and local deployment wrapper were modified before these notes were added. The untracked floci/ directory remained untouched.

Storage, snapshots of application configuration, S3 delivery objects, Secrets Manager, IAM, and local Terraform state remain. These application configuration snapshots are files on EBS, not AWS EBS snapshots. Stopping EC2 does not remove retained-resource charges.