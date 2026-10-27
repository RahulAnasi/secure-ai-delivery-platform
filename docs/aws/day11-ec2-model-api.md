Day 11 — Deploy the secure model API on EC2
Implemented and verified: 27 October 2026. Branch: feat/aws-model-api-deployment. Started from main at 44223a4, the Day 10 merge. These notes describe the observed implementation before the Day 11 commit/merge was confirmed.
What we achieved
We transferred an existing encrypted-model application image to the Day 10 EC2 server, without rebuilding it. The server downloaded the archive from private S3 using its IAM role. A systemd service retrieved the matching key from Secrets Manager into tmpfs and ran the hardened API container. Health, readiness, permissions and cleanup passed. A fresh service start passed. Terraform reported no changes before shutdown, and the user confirmed EC2 stopped.

This was the first application deployment onto our AWS server. It used the verified local Day 9 artifact, not the separately published JFrog CI artifact. Neither Jenkinsfile changed. A full EC2 reboot/restart recovery, prediction request, public endpoint, registry-based deployment and automated deployment rollback were not demonstrated.
The delivery flow
WSL: verify existing image/key pair → export image → record archive checksum → upload to private S3.

EC2: instance role downloads exact archive → verify checksum → load image → systemd retrieves runtime key → Docker starts non-root API → decrypt model into container tmpfs → check health/readiness.

Terraform defines bucket controls and runtime permissions. It does not upload the archive, install Docker or configure the operating-system service automatically. Those host operations were performed through Session Manager, with the service setup recorded in a repository script.
File map
File	Purpose
aws/iam/day11-operator-policy.json	Permission definition manually created as a customer-managed policy and attached to secure-api
deploy/aws/dev/artifact.json	Non-secret delivery record: source ID, archive checksum/size, runtime ID, region and secret name
deploy/aws/dev/configure-model-api-service.sh	Recorded host setup block; installs the launcher and systemd unit on the expected Amazon Linux EC2 host
infra/terraform/environments/dev/delivery.tf	Private S3 bucket, ownership controls, default encryption, public-access block and HTTPS-only policy
infra/terraform/environments/dev/runtime-access.tf	Existing secret metadata lookup and exact artifact/secret read permissions on the EC2 role
infra/terraform/environments/dev/outputs.tf	Added delivery bucket, object key and secret ARN outputs
app/secure-model-api/.build/day11/secure-model-api.tar.gz	Generated image archive; ignored by Git
/usr/local/libexec/secure-model-api-run on EC2	Retrieves the key and executes Docker in the foreground
/etc/systemd/system/secure-model-api.service on EC2	Supervises startup, shutdown, bounded retries and temporary directory lifecycle
/run/secure-model-api/model-key on EC2	Temporary runtime key; exists only while service operation needs it


Keep the untracked floci/ files outside the Day 11 commit. Keep Terraform state, backup state, saved plans and .terraform/ out of Git. Preserve local state for later management; ignoring it does not make it disposable.
1. Confirm our starting point
We checked Git status, Terraform state entries and available local images, refreshed the expired AWS browser login, and created feat/aws-model-api-deployment.

aws login --profile secure-ai-dev --region ap-south-1 --remote refreshes the operator login. secure-ai-terraform obtains credentials from that login through credential_process. They identify the same secure-api IAM user.

terraform state list showed the Day 10 infrastructure still tracked locally. This reads state; it does not start EC2. docker image ls secure-model-api showed the old CI images and dev-local.

Local commands use AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true to ignore configured emulator endpoints. The project root is /home/rahul/projects/secure-ai-delivery-platform; Terraform's working directory is infra/terraform/environments/dev.
2. Select and verify the model/key pair
Day 9 had established that the AWS key matched dev-local, while it did not authenticate the CI image. We selected the verified pair rather than treating all images as interchangeable.

The CLI retrieved secure-ai/day9/model-key and piped its value directly into a temporary local container's standard input. Python read the encrypted model and called decrypt_model. The container had no network, a read-only root and dropped capabilities. The key and plaintext model were not printed; decryption remained in Python process memory.

set +x disables shell tracing. set -euo pipefail makes failures, including a failed upstream AWS retrieval, fail the command group. The user received PASS: AWS runtime key authenticates and decrypts this image model.

This proved the current key matched the chosen model. It was not a full image vulnerability scan or proof that every possible secret was absent from every layer.
3. Export without rebuilding
docker image inspect --format '{{.Id}}' secure-model-api:dev-local resolved the source identity. An expected-prefix guard rejected an unexpected tag change. docker image save IMAGE_ID | gzip -1 created the delivery archive. No Docker build ran.

The Python packaging step hashed the compressed file, recorded its size and wrote artifact.json. git check-ignore confirmed the archive was ignored.
Identifier	Recorded value
Source label	secure-model-api:dev-local
WSL source Docker ID	sha256:8f19e7942102ca96ad506dd0147582471fc83ea7a7222788378c09ce218c73b5
Archive SHA-256, hexadecimal	75f93b0280ebc19c8fc60565b6b610fed07a1b70997db9e5781685475c041fd8
Archive size	58,381,881 bytes, approximately 55.7 MiB
EC2 runtime/configuration ID	sha256:f4ad4cbaca59d27820e44f49c0836f0395b337290bb45878df52bee423da1b75
Platform	linux/amd64


Do not label the current Git commit as the original image's source revision: that provenance was not established. source_label is a label, not an immutable registry reference. The archive hash identifies transferred bytes; it is not a signature or builder attestation.
4. Delegate operator permissions
Admin manually created and attached SecureAI-Day11-DeploymentOperator to secure-api. The JSON file records the permission definition; saving JSON alone does not grant AWS access.

Bucket permissions target secure-ai-delivery-884596874125-ap-south-1-dev. Object read/write/delete permissions target only artifacts/* within that bucket. IAM GetRolePolicy, PutRolePolicy and DeleteRolePolicy target the existing secure-ai-dev-ec2-role.

This delegation allows managing inline permissions on that role, not merely the exact runtime statement intended. It is powerful lab provisioning access, not a complete production permissions boundary.

Two reads were omitted initially and subsequently added to both the local definition and the customer-managed policy's default version:
- secretsmanager:GetResourcePolicy on the exact existing model-key secret ARN. The Terraform secret metadata data source also reads its attached access policy. This does not retrieve the key value.
- s3:GetAccelerateConfiguration on the delivery bucket. The API is called GetBucketAccelerateConfiguration, but its IAM action lacks Bucket. Therefore s3:GetBucket* did not cover it. Reading this setting does not enable acceleration.
Existing Day 10 and Day 9 permissions remained attached. We used customer-managed policies rather than hitting the IAM user's aggregate inline-policy size limit again.
5. Define delivery storage and runtime access in Terraform
The manifest is loaded with jsondecode(file(...)). From the dev Terraform directory, ../../../../deploy/aws/dev/artifact.json reaches the repository's deployment metadata.

The object key is artifacts/ARCHIVE_SHA256/secure-model-api.tar.gz. This makes selection content-based, but the path convention by itself does not enforce immutability.

The bucket configuration enables all four public-access blocks, BucketOwnerEnforced ownership, default AES256/SSE-S3 encryption, and a bucket policy denying requests where aws:SecureTransport is false. force_destroy=false prevents automatic deletion of a populated bucket during Terraform cleanup. Versioning and Object Lock were not enabled.

The existing secret is read through aws_secretsmanager_secret, which supplies metadata and its exact ARN. We do not use a secret-version data source; the secret value is not brought into Terraform state by this configuration.

The EC2 role's inline policy secure-ai-dev-runtime-read allows only GetObject on the selected exact archive and GetSecretValue on the selected exact secret. It grants no uploads, listing or secret modification. The policy references bucket/secret identifiers, so Terraform builds the appropriate dependency graph.

Five bucket-related resources plus the role policy were intended: six total additions, with no EC2 replacement.
6. Recover the failed plans/apply safely
The first preview found two issues. The secret metadata read lacked GetResourcePolicy. Also, stopped EC2 had no public IP and the provider proposed replacing it for associate_public_ip_address=false→true. We did not apply that plan.

After adding the read permission and starting the existing instance, a fresh plan showed six additions, zero changes and zero destruction. The public IP changed after restart, but instance i-06351ac1f906a192d remained the same. Starting compute resumed billing. We did not hide the issue with ignore_changes or edit state manually.

Applying day11.tfplan created the bucket but failed on the acceleration read permission. Terraform recorded the bucket in state and marked it tainted because creation had not completed successfully from the provider's perspective.

We added the missing read, inspected state and generated a new plan. It explicitly attributed bucket replacement to taint. Refresh now succeeded. head-bucket --expected-bucket-owner 884596874125 confirmed the intended owner/access.

terraform untaint aws_s3_bucket.delivery removed the state marker without changing the AWS bucket. This was appropriate after establishing the bucket existed, was readable and did not otherwise require replacement. It is not a universal way to suppress failed infrastructure checks.

The saved recovery plan reported five additions and no destruction because the bucket already existed. We used day11-recovery.tfplan rather than the obsolete earlier plan. Subsequent evidence confirmed all bucket controls and the runtime role policy were present.

A failed apply can leave real resources. Never assume failure means nothing was created; inspect state and a new plan before retrying, deleting or importing.
7. Verify and upload to S3
Read-only CLI checks confirmed all four public blocks true, AES256 encryption, BucketOwnerEnforced and the HTTPS-only deny policy. BucketKeyEnabled=false was normal for this SSE-S3 configuration; it did not mean encryption was disabled. The response also showed SSE-C blocked.

Before upload, sha256sum checked the local archive against artifact.json. Python converted the same SHA-256 from hexadecimal to Base64 for the S3 API.

put-object used the exact key, expected bucket owner, AES256 encryption, SHA256 checksum and --if-none-match '*'. The condition prevents that upload command overwriting an existing object; it does not establish an immutable bucket-wide policy. A repeated upload may return PreconditionFailed and should trigger inspection of the existing object, not automatic deletion.

head-object --checksum-mode ENABLED returned object metadata. We compared its checksum and content length with the manifest. The user received PASS: S3 archive checksum and size match the manifest. We did not use ETag as a SHA-256 digest.
8. Prepare EC2 and verify the loaded artifact
We connected from WSL through Session Manager using the existing instance-specific operator policy. Commands after connection ran on EC2, not WSL.

On Amazon Linux, sudo dnf install -y docker installed Docker. sudo systemctl enable --now docker started it and enabled boot startup. No Docker-group membership was added; host administration uses sudo.

Observed Docker client was 25.0.14 and server 25.0.18. Root disk had about 6 GiB free; memory available was about 455 MiB. There was no swap configured in the reported output.

The server used its instance role, without a named local AWS profile. We created /opt/secure-model-api/artifacts with root-only directory access and used sudo aws s3api get-object to write there. sudo grants local filesystem access; it does not grant AWS authorization.

After download, sha256sum verified the compressed archive. docker image load imported it without rebuilding or starting it.

The first expected-ID check failed: Docker on EC2 reported f4ad... rather than the original WSL 8f19... identifier. Docker image stores can expose manifest/index and configuration identifiers differently; treating IMAGE ID as universally identical across stores was too simplistic.

We did not just accept the new ID. A Python script read manifest.json and the referenced configuration from the checksum-verified archive without extracting files. It hashed the configuration bytes, inspected the loaded image by that digest, and compared layer diff IDs, operating system, architecture and configured user. All checks passed, including UID 10001:10001.

artifact.json was later extended with runtime_image_id and runtime_platform, preserving the original source ID and archive hash. The hash of the archive did not change.
9. Configure systemd and runtime secrets
The setup block is recorded in deploy/aws/dev/configure-model-api-service.sh. It was executed on EC2 through the interactive terminal, not automatically by Terraform. It verifies Amazon Linux 2023 and the expected assumed-role ARN before writing host files.

It creates a root-owned launcher and systemd unit. bash -n and systemd-analyze verify validate syntax; daemon-reload tells systemd to read the unit. Configuration alone does not start it.

The host unit runs as root to operate Docker and protect /run. The actual application container runs as UID/GID 10001. These are separate privilege boundaries.

On service startup, systemd creates /run/secure-model-api with mode 0700. The launcher checks that it is on tmpfs before retrieving the key. AWS CLI output goes directly to model-key, not the journal. umask 077 restricts new files; chown/chmod set the file to UID/GID 10001 and mode 0600.

Service environment ignores configured endpoint overrides, sets the region, disables CLI prompting and points local AWS configuration/credentials files to /dev/null. The EC2 role supplies temporary credentials. No application AWS access keys are passed into Docker.

Docker runs the verified configuration ID with --pull never, --rm, --init, non-root user, read-only root, all capabilities dropped, no-new-privileges, 256 MiB memory, 1 CPU and a 100-process limit. /tmp and /dev/shm use restricted tmpfs mounts. The key file is bind-mounted read-only. Docker logs use the local driver with 10 MiB files and three retained files.

The API is bound to 127.0.0.1:8000 on EC2. We did not open an inbound security-group rule or expose a public API. Host root and Docker administration remain trusted.

The foreground exec docker run lets systemd supervise the process. The unit stops/removes the container and removes its key on shutdown. RuntimeDirectory is removed after stopping. Restart=on-failure is bounded by the start-limit settings. Enabling the unit configures future boot startup but does not by itself prove a successful reboot test.
10. Startup troubleshooting and successful verification
The first readiness loop failed because the unit was disabled/inactive, with no journal entries. We had not actually completed startup. We validated both files and ran systemctl enable --now secure-model-api.service.

The acpid.socket legacy-path warning referred to an unrelated system unit. The pre-start Docker cleanup reported no existing container on the first run; that command intentionally tolerates absence. Neither message established an application failure.

Immediately after startup, status showed AWS CLI retrieving the secret. Type=simple active does not mean HTTP readiness. We waited for /ready, then checked both API routes and the container.
Check	Observed result
/health	status healthy
/ready	status ready; model_loaded true
Container	healthy, loopback port 8000
Service restart count	NRestarts=0 after initial successful startup
App identity	UID/GID 10001:10001
Root filesystem	ReadOnly=true
Dropped capabilities	ALL
Security option	no-new-privileges:true
Key bind mount	KeyMountRW=false
Host key	600, owner 10001:10001, tmpfs
Decrypted model	600, owner 10001:10001, tmpfs


The key was at /run/secure-model-api/model-key on the host and /run/secrets/model-key inside the container. The model plaintext was at /dev/shm/model.bin inside the container. No contents were printed during verification. Tmpfs is memory-backed; it is not a universal guarantee of forensic erasure or protection from a privileged host.
11. Verify cleanup and fresh startup
We explicitly stopped the application service. Docker remained available, the application container no longer existed, and /run/secure-model-api was absent. This demonstrated cleanup, while the AWS secret and loaded image remained available.

We then started the service again. Readiness passed, the key file was recreated, and systemd reported active/enabled. Docker briefly showed health: starting at three seconds, which was consistent with its scheduled health-check interval despite the successful direct readiness response.

This demonstrated a service stop/start cycle after key/container cleanup. It did not demonstrate a full EC2 boot recovery or secret rotation.
12. Final state and costs
Before stopping EC2, the final Terraform plan reported: No changes. Your infrastructure matches the configuration. This verifies Terraform-managed infrastructure, not host configuration installed manually.

The user then confirmed EC2 state stopped. Compute stopped; EBS, the S3 object and the Secrets Manager secret remain retained and billable. The automatic public IP is released and can change on the next start. The service remains enabled, and the installed image/service files persist on EBS. We have not yet demonstrated their recovery through a full server restart.

Do not apply an old plan after stop/start. In this lab, planning while stopped produced a public-IP-association replacement proposal; restart the existing instance and inspect a fresh plan before any apply. Never accept an unexpected destroy/replacement merely because other additions are intended.
Commands to remember
Command	Meaning
terraform plan	Preview changes; inspect actions, not only output values
terraform apply SAVED_PLAN	Execute exactly that plan, without another yes prompt
terraform state list	Inspect tracked addresses
terraform untaint ADDRESS	Remove a justified taint marker from state; not a general error fix
docker image save / load	Transfer existing image content without building
sha256sum --check	Compare file bytes with the expected digest
aws s3api head-object	Read object metadata, not its body
systemctl daemon-reload	Load updated service definitions
systemctl enable --now	Configure boot startup and start now
systemctl stop	Stop the service; does not stop EC2
journalctl -u secure-model-api.service	Read service logs
exit in a session	Disconnect shell; does not stop service or instance


Git handoff and mental model
Commit the operator JSON, artifact manifest, service-setup script, delivery/runtime Terraform files, changed outputs and these project notes. The archive and key values must not be staged. Inspect staged paths explicitly; leave floci/ untouched. Commit and PR completion are not yet claimed in this guide.

Mental model: the operator can provision and upload; the instance role can read only its artifact and secret; systemd manages host startup and cleanup; Docker supplies the application runtime restrictions; the application authenticates/decrypts the model before becoming ready. The archive checksum links the transferred bytes across machines even when their Docker image-store IDs differ.

Recruiter explanation: I deployed a prebuilt encrypted-model API onto an EC2 development server. Terraform managed private S3 delivery controls and narrowly scoped runtime read permissions. The server used its IAM role to retrieve the artifact and key, and systemd launched a non-root Docker container with a read-only filesystem and tmpfs-backed key/model files. I verified archive integrity, image configuration, API readiness and stop/start cleanup, then stopped compute after a no-change Terraform plan. The exercise used a verified local artifact; CI registry-to-EC2 automation remains a separate integration task.