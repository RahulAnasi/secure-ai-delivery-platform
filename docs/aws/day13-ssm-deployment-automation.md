Day 13 — Deploying the Model API through AWS Systems Manager
Implementation and live verification: 28 October 2026. These notes record observed results; the Day 13 commit and merge were still pending when written.
1. Goal and starting point
Deploy the existing approved application to the existing EC2 development server from WSL, without opening an interactive EC2 terminal.

Days 10–12 had already created the infrastructure, deployed the application manually, and verified automatic recovery after an EC2 stop/start. Day 13 automated the deployment procedure using Systems Manager Run Command.

We reused the Day 11 local development image and matching Day 9 secret. We did not rebuild the image or deploy a newly promoted JFrog artifact.

Starting repository: main at ce2faa7, the merge of PR #12. Working branch: feat/ssm-deployment-automation.
2. The complete flow
1. WSL authenticates to AWS using the operator profile.
2. The local deployment script packages four explicitly selected files.
3. The command runner submits a Bash script using ssm send-command.
4. The SSM agent on EC2 executes the instructions as root.
5. EC2 uses its instance role to download the selected S3 archive.
6. The host deployment script verifies the archive and loads the approved image.
7. The existing setup script writes the runtime launcher and systemd service definition.
8. The host deployment script restarts the application service.
9. The runtime launcher retrieves the model key from Secrets Manager using the EC2 role.
10. The application decrypts its model into tmpfs and starts.
11. The deployment waits for Docker health and runs the existing full runtime verifier.
12. WSL retrieves the SSM execution result and returns success or failure.
Run Command transports instructions and results. S3 transports the image archive. Secrets Manager supplies the runtime key. These are separate responsibilities.
3. Files created and reused
File	Purpose	Runs where?
aws/iam/day13-run-command-policy.json	Records the operator's new Run Command permissions	Attached through IAM; JSON tracked in Git
scripts/run-dev-ssm-script.sh	Submits one non-secret Bash script, polls its execution, prints output, and returns an appropriate local exit code	WSL
scripts/deploy-dev-ssm.sh	Packages the approved deployment files and invokes the command runner	WSL
deploy/aws/dev/deploy-on-host.sh	Downloads, validates, loads, configures, restarts, and verifies the deployment	EC2
deploy/aws/dev/artifact.json	Existing approved artifact identity, archive checksum/size, platform, and secret reference	Read during deployment
deploy/aws/dev/configure-model-api-service.sh	Existing Day 11 service installer; writes the host launcher and systemd unit	EC2
deploy/aws/dev/verify-runtime.sh	Existing Day 12 runtime and security verifier	EC2


Day 13 did not modify Terraform configuration or either Jenkinsfile. The untracked floci/ files were left alone.
4. Operator identity versus server identity
The WSL operator authenticated as IAM user secure-api in account 884596874125. The secure-ai-terraform profile retrieves temporary credentials from the secure-ai-dev login profile.

When the login expired, we refreshed it with:
aws login --profile secure-ai-dev --region ap-south-1 --remote
We verified the identity with sts get-caller-identity using the secure-ai-terraform profile.

The EC2 host uses secure-ai-dev-ec2-role, through its instance profile, to access the selected S3 object and model secret. Operator credentials are not copied to EC2 or the application container.

Run Command executed as Linux root, unlike the interactive Session Manager shell, which used ssm-user. The application inside Docker still ran as UID/GID 10001:10001. Linux execution identity and AWS authorization identity are different concepts.
5. IAM permission added
Admin created and attached the customer managed policy SecureAI-Day13-RunCommand to secure-api.

The policy allows:
- ssm:SendCommand for AWS's AWS-RunShellScript document in Mumbai and instance i-06351ac1f906a192d only.
- ssm:GetCommandInvocation to retrieve results, with region restricted to Mumbai. This API action requires resource * because it does not support resource-level authorization.
This is permission to run arbitrary shell commands on the selected host, not just the scripts in this repository. The local script checks are additional safeguards, not an IAM restriction on command content. No new iam:PassRole permission was needed for this direct command submission.

If the EC2 instance is replaced, both the operator's instance-specific permission and the runner's approved target check must be reviewed and updated.
6. Bringing the host online
We started the existing instance, waited for instance-running and instance-status-ok, and checked ssm describe-instance-information for Online.

Running EC2 status checks and being reachable through SSM are separate checks. No public inbound SSH rule was added. The existing SSM agent and instance-role configuration were reused.

The host's boot ID during Day 13 was a379c4c1-797d-4c1a-8fec-1f76e97a56eb.
7. First tests before deployment
Read-only connection test
We submitted hostname, id, and systemctl is-active docker.service using AWS-RunShellScript.

Result: SSM Success, exit code 0, Linux execution identity root, Docker active.

Command ID: 2362ca83-1fdb-4e90-8b02-ba4ed2aca867.
Remote runtime verification
We first sent the existing Day 12 verifier directly, then ran it through the reusable runner:
./scripts/run-dev-ssm-script.sh deploy/aws/dev/verify-runtime.sh
Both succeeded. The reusable-runner verification command ID was 39eb626a-cb99-478c-92e9-e84d57a6bc72.

The application had automatically started after the EC2 boot. Its service was active since 2026-10-28T11:16:37Z, with NRestarts=0.
Deliberate failure test
A temporary script printed a message and executed exit 23. It did not modify the application.

Observed results:
- Remote SSM status: Failed.
- Remote process exit code: 23.
- Local command runner exit code: 1.
Command ID: 665fdc63-c6e4-4312-a7c8-9d7d208c6983.

This proved that the runner propagates failure to its caller. A future Jenkins stage can fail on that nonzero return code. It does not preserve every remote exit code exactly; it reports unsuccessful execution as local code 1.
8. Understanding the command runner
run-dev-ssm-script.sh accepts exactly one existing, nonempty local Bash script. It checks Bash syntax before submission.

It then:
- Checks the AWS account using STS.
- Reads the instance ID from the existing local Terraform output.
- Confirms that it matches the approved instance.
- Uses jq --rawfile to JSON-encode the script without breaking quotes or newlines.
- Wraps the contents in a Bash heredoc with a generated delimiter.
- Calls ssm send-command and prints the returned command ID.
- Polls ssm get-command-invocation every five seconds.
- Retries the initial InvocationDoesNotExist visibility delay, but surfaces other API errors.
- Prints the result and returns 0 only for SSM Success with response code 0.
The remote execution timeout is 600 seconds. The local polling deadline is 900 seconds, although network/API calls can add time. Timing out or closing WSL does not necessarily cancel an already submitted remote command. Keep the command ID for investigation.

The runner's temporary local request/result directory is removed by an EXIT trap. SSM can retain command instructions and output, so scripts must contain no secret values. The runner itself does not inspect scripts for secrets.
9. Understanding the local deployment package
The normal deployment entry point is:
./scripts/deploy-dev-ssm.sh
It packages exactly four files: the artifact manifest, service setup script, runtime verifier, and host deployment script. It does not archive the entire repository, environment files, model key, or image archive.

Python creates a compressed tar archive in memory and Base64-encodes it. Base64 preserves bytes for transport; it is not encryption. The submitted script measured 7,850 bytes in the successful run, below our conservative 24,000-byte inline guard.

On EC2, a generated wrapper uses a private temporary directory under /var/tmp, decodes and unpacks this known package, and calls deploy-on-host.sh with that directory. Its EXIT trap removes the package afterward. Normal deployment success was observed; package cleanup was implemented through the trap, not independently checked afterward.

The wrapper disables configured emulator endpoints and clears the usual static access-key environment variables and profile selection. It directs AWS config and credentials file paths to /dev/null. The host deployment additionally checks that STS reports the expected EC2 role.
10. Understanding the host deployment
The host script uses Bash to launch embedded Python. Python coordinates AWS CLI, Docker, systemd, and the existing Bash scripts through checked subprocess calls.

Before restarting the application it validates:
- Execution as root and presence/syntax of the package scripts.
- Manifest schema, expected region, platform, secret reference, filename, size, and checksum format.
- The runtime image ID supported by the existing service installer.
- The expected EC2 role.
It downloads from the private bucket secure-ai-delivery-884596874125-ap-south-1-dev, using the key artifacts/<archive_sha256>/secure-model-api.tar.gz and expected bucket owner.

Download checks:
1. Save to a .download file.
2. Compare byte size to the manifest.
3. Compute SHA-256 locally and compare it to the manifest.
4. Read the Docker archive's manifest.json and image configuration without extracting the image filesystem.
5. Require exactly one image and the approved configuration digest, Linux/amd64 platform, and non-root configured user.
6. Rename the verified download to the final archive path.
7. Load it into Docker and compare its configuration ID and root filesystem layer identifiers to the archive metadata.
The checksum proves the bytes match our approved manifest. It is not a cryptographic image signature or an independent provenance attestation.

After image validation, the script reuses the existing installer, enables the Docker and application services, and restarts the application service. It waits approximately two minutes for Docker health, then runs the full runtime verifier with the approved image ID.

The existing installer writes and reloads configuration but does not itself start the service. Its message about not starting the service describes that installer's action; the surrounding deployment script starts it through systemctl restart.
11. Approved artifact identities
Identity	Value
Original local label	secure-model-api:dev-local
Original local image ID	sha256:8f19e7942102ca96ad506dd0147582471fc83ea7a7222788378c09ce218c73b5
Runtime image configuration ID	sha256:f4ad4cbaca59d27820e44f49c0836f0395b337290bb45878df52bee423da1b75
Archive SHA-256	75f93b0280ebc19c8fc60565b6b610fed07a1b70997db9e5781685475c041fd8
Archive size	58,381,881 bytes
Runtime secret reference	secure-ai/day9/model-key


We retained both image identifiers because the local and EC2 Docker stores exposed different identities. The archive checksum, embedded configuration digest, and loaded layer checks link the approved package to the deployed runtime. Do not treat every Docker image ID, registry manifest digest, and archive checksum as interchangeable.
12. Successful deployment evidence
Command ID: 1a219265-93e3-4102-a09e-599155db25f3.

Observed:
- SSM status Success, exit code 0.
- Downloaded archive size and checksum matched.
- Archive configuration and loaded image/layers matched.
- Service configuration validated and application restarted.
- All runtime verification checks passed.
- Service NRestarts=0 after deployment. This counts automatic service restarts, not the explicit restart requested by deployment.
- Application active since 2026-10-28T11:36:22Z.
Checks covered non-root UID 10001, read-only root filesystem, dropped capabilities, no-new-privileges, 256 MiB memory, one CPU, 100-process limit, loopback-only port 8000, read-only key mount, restricted key/model ownership and permissions, tmpfs storage, HTTP health/readiness, and model loaded.

systemd-analyze verify emitted an unrelated acpid.socket warning about legacy /var/run. Deployment and readiness succeeded; no application fix was required for that warning.
13. Boundaries and limitations
- This is deployment to one existing development server, not a multi-environment rollout.
- Restarting the single container briefly interrupts the API.
- There is no automatic rollback. A failure after restart can leave the service unavailable and requires investigation.
- The deployment is pinned to the current Day 11 image/key pair. Supporting another approved artifact requires reviewing the manifest, service installer, IAM object access, and relevant checks together.
- No Jenkins deployment stage was added. CI/JFrog releases are not yet connected to this process.
- Docker installation and infrastructure provisioning are prerequisites, not handled by this script.
- Do not submit concurrent deployments to this server; no deployment lock was added.
- SSM output retrieval has size limits; this run's output fit the returned result. Full external log storage was not configured.
- Syntax checks and the live success/failure tests passed. We did not deliberately corrupt the archive, force a deployment health failure, test timeout cancellation, or prove rollback.
14. End-of-day state and repeat use
The EC2 instance was stopped and confirmed stopped after testing. EBS, S3, Secrets Manager, IAM, and Terraform state remain. Stopping EC2 does not remove retained-resource charges.

To repeat later:
1. Refresh AWS login if required and verify the operator identity.
2. Start the existing instance and wait for EC2 status checks and SSM Online.
3. Review the approved manifest and deployment scripts.
4. Run ./scripts/deploy-dev-ssm.sh from WSL.
5. Confirm SSM Success, exit code 0, and the runtime checks.
6. Stop the lab instance when finished and verify its state.
No Terraform apply was needed on Day 13. Preserve the existing local Terraform state. If planning while EC2 is stopped, review the previously observed public-IP-related replacement issue rather than applying a replacement blindly.
15. Mental model and interview explanation
Terraform creates the server and its permissions. SSM delivers instructions. S3 holds the approved image archive. The EC2 role authorizes artifact and secret retrieval. Systemd manages the application process. Docker enforces runtime restrictions. The verifier supplies deployment acceptance evidence.

“I automated deployment of an encrypted-model API to an existing EC2 server using Systems Manager Run Command. A local wrapper packages the deployment scripts, EC2 validates the approved S3 archive and image identity before restarting, and the service obtains its runtime key through an instance role. The deployment runs health and security checks and returns failures to the caller. I tested both successful deployment and remote failure propagation. Jenkins integration and automatic rollback are subsequent work.”