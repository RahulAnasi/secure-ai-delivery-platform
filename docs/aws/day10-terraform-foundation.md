Day 10 — Terraform EC2 foundation and Session Manager
Outcome
Implemented and verified on 26 October 2026 in Mumbai (ap-south-1). Terraform created 12 resources. EC2 was healthy, Session Manager worked without inbound rules, the system disk was encrypted, and a subsequent plan reported no changes. The user confirmed the instance was stopped after verification.

This day established infrastructure and administrative access. Application deployment, model-secret access from EC2, remote Terraform state and Jenkins infrastructure automation were not implemented. Day 9 remains complete and unchanged. Neither Jenkinsfile changed on Day 10.
Starting point and branch
Repository: /home/rahul/projects/secure-ai-delivery-platform.

The working copy initially remained on feat/aws-runtime-secrets even though its PR had been merged. We switched to main, pulled using git pull --ff-only origin main, and created feat/aws-terraform-foundation. Starting commit was 94d8f23, the Day 9 merge. Untracked floci/ was left alone.

git status --short --branch checks branch and unfinished work. git log -1 --oneline identifies the revision. A GitHub merge does not switch a local branch. Terraform 1.13.0 was retained; its upgrade notice did not require upgrading to complete this lab.
Authentication: two profiles, one operator
The initial AWS session had expired. aws login --profile secure-ai-dev --region ap-south-1 --remote refreshed temporary browser-login credentials. The identity was secure-api, not Admin.

We configured a second local profile:
aws configure set region ap-south-1 --profile secure-ai-terraform
aws configure set output json --profile secure-ai-terraform
aws configure set credential_process \
  'aws configure export-credentials --profile secure-ai-dev --format process' \
  --profile secure-ai-terraform
This stores a credential-provider command, not static keys in Terraform. secure-ai-dev holds the login; secure-ai-terraform obtains credentials through the CLI. Both represent secure-api. We did not print exported credentials.

sts get-caller-identity verified the profile. AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true was used for local AWS/Terraform operations to ignore configured emulator endpoints. Login expiration still requires renewing secure-ai-dev.
File map
All Terraform files are under infra/terraform/environments/dev/. Terraform reads the directory's .tf files together; filenames do not specify execution order.
File	Responsibility
versions.tf	Accept Terraform >=1.13.0 and <2.0.0; require hashicorp/aws provider major version 6
providers.tf	Select Mumbai, secure-ai-terraform and the allowed AWS account; default project/environment/management tags
main.tf	Read the current AWS caller identity
outputs.tf	Expose account, identity, network IDs, instance ID/IP, role ARN and AMI ID
network.tf	Define VPC, subnet, gateway, routes, association, security group and HTTPS egress
iam.tf	Define EC2 trust, role, Systems Manager policy attachment and instance profile
bootstrap.sh	Enable and start amazon-ssm-agent during first boot
compute.tf	Resolve the Amazon Linux image and define the EC2 instance and root disk
.terraform.lock.hcl	Record selected provider version and checksums; commit it


aws/iam/day10-session-access-policy.json records operator session permissions. It was generated locally from Terraform outputs, then manually created and attached in IAM. Saving JSON in Git does not itself grant permissions.

The Terraform configuration manages the EC2 role and profile. The operator permission policies were created manually using Admin; Terraform does not manage those policies.
First Terraform checks
The initial configuration had only a caller-identity data source and outputs. A data source reads information; a resource describes something Terraform manages.
Command	Purpose and result
terraform fmt	Format configuration; not an AWS permission check
terraform init	Initialize the directory and download the provider; generate the lock file
terraform validate	Check syntax and internal consistency; not remote authorization
terraform plan	Contact AWS, read data and preview proposed changes; create no infrastructure


The initial plan showed the expected operator account and ARN, proving Terraform authentication worked.
Authorization and the policy-limit correction
EC2 DescribeVpcs failed with UnauthorizedOperation. SSM GetParameter for the public Amazon Linux parameter failed with AccessDeniedException. These were missing permissions, not failed authentication.

Using Admin in the browser, we created and attached customer-managed policy SecureAI-Day10-TerraformFoundation to secure-api. Existing Day 8 and Day 9 policies remained attached.

The original attempt used an inline policy and exceeded the 2,048-character user limit. This limit applies across all inline policies on the user. The correction was a customer-managed policy, whose individual limit is 6,144 characters, excluding whitespace. Splitting the JSON into more user inline policies would not fix the aggregate limit.

The policy grants listed EC2 network/instance lifecycle operations in Mumbai, the specific public AMI parameter lookup, management of secure-ai-dev-ec2-role and secure-ai-dev-ec2-profile, attachment of AmazonSSMManagedInstanceCore, passing that role only to EC2, and SSM connection-status reads.

The EC2 operations are region-scoped lab permissions across Mumbai resources. A statement's name does not enforce project-tag restrictions. The IAM role/profile names and managed-policy attachment are explicitly restricted. This is not a claim of complete production least privilege.

Repeating the read checks returned a VPC count of 1 and an AMI ID. The existing VPC was not adopted: our configuration creates its own network.
Network design: eight resources
1. VPC, CIDR 10.42.0.0/16, with DNS support and hostnames enabled.
2. Subnet, CIDR 10.42.1.0/24, in the first available standard AZ returned for the account: ap-south-1a.
3. Internet gateway attached to the VPC.
4. Route table for the subnet.
5. Default IPv4 route, 0.0.0.0/0, to the gateway.
6. Route-table association connecting the subnet to that table.
7. Server security group with no inbound rules.
8. Separate egress rule allowing TCP 443 to all IPv4 destinations.
local.name_prefix centralizes the secure-ai-dev naming prefix. References such as aws_vpc.dev.id connect resources and establish dependencies.

A public subnet has an internet-gateway route. Its name alone changes nothing. The subnet's automatic public-IP setting is false; the EC2 resource explicitly requests its public IP. Routing, addressing and security-group rules must all permit a connection. A public IP does not automatically open inbound access.

The security-group rules are standalone resources; do not mix inline ingress/egress rules into the same group. No NAT gateway, load balancer or VPC interface endpoint was created.

The network-only preview reported 8 additions, 0 changes, 0 deletions.
EC2 identity: three resources
The trust document permits ec2.amazonaws.com to assume the role. This answers who may use the role; it does not itself grant service permissions.

The role secure-ai-dev-ec2-role receives AmazonSSMManagedInstanceCore through a policy attachment. The profile secure-ai-dev-ec2-profile associates that role with EC2.

The server receives temporary credentials through its instance role. We did not copy secure-api access keys onto it. This role currently provides Systems Manager access, not the Day 9 model-secret permissions.
Compute: one resource
The public parameter /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 supplies an AMI ID. A second data source verifies an available Amazon-owned x86-64 image. Public parameter lookup is unrelated to reading a private model secret.

The instance is t3.micro, with 2 vCPUs and 1 GiB memory. CPU credits use standard mode to avoid Unlimited surplus-credit charges; sustained workloads can be throttled.

The root disk is 8 GiB gp3, encrypted, with delete_on_termination enabled. Stopping preserves the disk; termination removes this root volume as configured.

Metadata requires IMDSv2 tokens, has hop limit 1 and disables instance-tag exposure through metadata. The endpoint remains enabled because the host needs role credentials.

file("${path.module}/bootstrap.sh") supplies the startup script as user data. It contains no secrets. The script runs systemctl enable --now amazon-ssm-agent. Changes to user data are configured to propose instance replacement. Explicit dependencies ensure internet routing and the role policy attachment precede launch.

The AMI lookup follows the latest public parameter. A later image update may cause a future plan to propose replacement; inspect plans rather than assuming every plan is harmless.
Save and apply the plan
The complete preview reported 12 additions: eight network resources, three IAM resources and one instance. Data sources and outputs are not additional provisioned resources in this count.

We checked Git ignore handling for terraform.tfstate, terraform.tfstate.backup, day10.tfplan and .terraform/. umask 077 restricted permissions on newly created local files.
terraform plan -out=day10.tfplan
terraform apply day10.tfplan
The saved plan captures the planned operations. Applying a saved plan executes without another yes prompt. The user reported success; subsequent state refresh listed all 12 resources.

State maps Terraform resource addresses to real AWS IDs. Preserve it locally while using this local backend. Do not commit state, plans or provider binaries. The lock file belongs in Git. Losing state is not the same as deleting AWS resources.
Verified deployment evidence
Check	Recorded result
EC2 state/type	running / t3.micro
EC2 system and instance checks	both ok
Attached profile	secure-ai-dev-ec2-profile
Metadata tokens	required
Security-group inbound	empty list
Security-group outbound	TCP 443 only, IPv4 destination 0.0.0.0/0
Systems Manager	Online, agent 3.3.5390.0
Operating system	Amazon Linux 2023.12.20261026
Remote Linux user	ssm-user, UID/GID 1001
cloud-init	status: done
Agent service	active
Root volume	encrypted, 8 GiB, gp3
Final pre-stop Terraform plan	No changes. Your infrastructure matches the configuration.
Server AWS identity	assumed-role/secure-ai-dev-ec2-role/i-06351ac1f906a192d
End-of-session state	user confirmed stopped


The no-change plan was run before stopping the instance. We have not claimed a second post-stop no-change check. EC2 health checks do not prove application health; no application was deployed today.
Operator session permission and plugin
A generated customer-managed policy, SecureAI-Day10-SessionAccess, was attached to secure-api using Admin. It allows StartSession on the specific instance and AWS-StartInteractiveCommand document. Channel/resume/terminate permissions target identity-derived session prefixes, covering user-ID and username formats. This grants an administrative shell, not command-restricted access.

The policy contains the current instance ID. If the instance is replaced, regenerate the file and update the IAM policy before connecting to the replacement.

The Session Manager plugin was absent from WSL. We downloaded the official Ubuntu AMD64 .deb from AWS and installed it with sudo dpkg -i. The download directory was temporary. A numeric plugin version was not pasted, but successful sessions proved the plugin worked.

The plugin runs on WSL; the SSM agent runs on EC2. These are different components.
aws --profile secure-ai-terraform --region ap-south-1 \
  ssm start-session --target INSTANCE_ID \
  --document-name AWS-StartInteractiveCommand \
  --parameters '{"command":["/bin/bash"]}'
Inside that session, hostname/id identified the remote machine and Linux account. /etc/os-release identified the OS, sudo cloud-init status --wait checked first-boot completion, and sudo systemctl is-active amazon-ssm-agent checked the service. exit closes the session but does not stop EC2.

A final short session ran aws sts get-caller-identity --region ap-south-1 --query Arn --output text on EC2. Its assumed-role ARN verified the server's AWS identity.
Three identities to remember
Identity	Function
Admin in browser	Bootstrap operator permissions in IAM
secure-api via WSL profiles	Run Terraform and authorize session requests
secure-ai-dev-ec2-role on EC2	Give host software temporary AWS permissions


ssm-user is the Linux shell account, not another AWS IAM user. Operator authentication, operator authorization, EC2 role authorization and Linux permissions are separate boundaries.
Stopping, restarting and deleting
The user ran stop-instances, waited with ec2 wait instance-stopped, and confirmed stopped. Compute stopped; the retained EBS disk still incurs storage charges. The automatic public IPv4 address is released and may change after restart. Existing Terraform output values can be stale until refreshed.

For a future session, from the dev Terraform directory, resolve the ID with terraform output -raw instance_id, then use the secure-ai-terraform profile in Mumbai to start-instances, wait instance-running and check EC2 health and SSM Online again. Do not run terraform apply merely to resume a stopped instance.

For permanent cleanup, review terraform plan -destroy and then deliberately run terraform destroy in this exact directory. That removes managed infrastructure, not just compute. Keep the state until cleanup succeeds. The manually created operator policies and local AWS profiles are outside this state and remain unless separately removed. This section is reference guidance; destroy was not executed.
Costs and limits
Billable items are instance runtime, retained gp3 storage and public IPv4 usage. IPv4 is $0.005/hour while assigned. The earlier $0.03/hour figure was a conservative working estimate, not a verified Mumbai quote or spending cap. Credits, eligibility, taxes, transfer and current billing must be checked separately. No current credit balance was verified today.

We used local state, a public subnet and one AZ for a small lab. This is not a highly available production deployment. There is no session transcript archival configured, remote state backend, application deployment, CI infrastructure job or secret retrieval on EC2 yet.
Git handoff
Commit configuration, bootstrap.sh, the lock file, the session policy definition and project documentation. Exclude state, plans, .terraform/, credentials and floci/. Use explicit paths with git add rather than git add .

Before committing, run terraform fmt -check, terraform validate, bash -n bootstrap.sh and git diff --check. Inspect git diff --cached --name-only and the staged diff. The guide was prepared before commit/PR confirmation; no Day 10 commit or merge is claimed here.
Mental model and recruiter explanation
Terraform describes the network, server and role. The provider uses the operator's temporary credentials to build that description in AWS. The server's SSM agent uses its own role to establish outbound connectivity. The operator then requests a permitted session; the local plugin opens a shell as a Linux user on the server. State records which real resources Terraform manages.

Recruiter explanation: I provisioned a development EC2 foundation in Mumbai using Terraform, with an isolated VPC, controlled routing, no inbound security-group rules, an encrypted root disk and IMDSv2. I attached a Systems Manager instance role, limited operator session access to the target instance, and verified administrative access without SSH keys. I checked the instance role identity and a no-change Terraform plan, then stopped the instance to control compute usage. Application deployment is the next integration task.