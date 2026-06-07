# Shopverse Infrastructure Plan v3 — Final

> **Greenfield build. All architectural decisions locked.** Last updated after full decision review.

---

## Architecture Overview

Three phases, two automation systems, one GitOps control plane.

**Phase 1 — Bootstrap:** GitHub Actions runs once (`workflow_dispatch`). Creates the minimal foundation: S3 state bucket, ECR repositories, VPC public layer, and a Jenkins EC2 instance. Jenkins bootstraps itself via user-data.

**Phase 2 — Main:** Jenkins runs. Provisions the full private platform via a two-stage pipeline: Terraform (network + EKS + RDS + jump server), then Ansible (ArgoCD + observability stack). Jenkins reaches all private resources via VPC routing — it is in the same VPC as everything else.

**Phase 3 — Application Delivery:** GitHub Actions runs on every push to application repos. Builds Docker images, pushes to ECR, commits updated image tags to the GitOps repo. ArgoCD (already running inside the private cluster) detects the change and syncs the cluster. GitHub Actions never touches the Kubernetes API or anything inside the VPC.

---

## Pre-Flight Checklist

Resolve all of the following before writing a single line of Terraform.

- [ ] Terraform 1.10+ installed locally (required for `use_lockfile = true`)
- [ ] AWS CLI configured with credentials sufficient to create S3, VPC, IAM, EC2 resources
- [ ] Naming prefix chosen and documented — applied to every resource without exception
- [ ] AWS region chosen and hard-coded in all backend configurations
- [ ] `kubectl` and `helm` installed locally for verification steps
- [ ] GitHub OIDC trust policy conditions decided — exact repo and branch, not wildcard
- [ ] AWS service quotas confirmed: EKS, NAT Gateway, VPC interface endpoints, EC2 instances
- [ ] IAM permission boundary policy drafted for the Jenkins role

---

## Phase 1: Bootstrap

Executed by: **GitHub Actions** (`workflow_dispatch` only, never triggered by push)

### 1.1 State Bootstrap Sequence

You cannot point a Terraform backend at an S3 bucket that does not yet exist. Follow this exact sequence — it is not optional:

```
Step 1: Write Bootstrap Terraform with NO backend block (uses local state)
Step 2: terraform init && terraform plan && terraform apply
        → S3 bucket now exists
Step 3: Add the backend block to Bootstrap pointing at the new bucket
        key = "bootstrap/terraform.tfstate", use_lockfile = true
Step 4: terraform init -migrate-state
        → Terraform moves local state into S3
Step 5: Verify state at s3://<bucket>/bootstrap/terraform.tfstate
Step 6: All future Bootstrap runs initialize directly against S3
```

The GitHub Actions workflow must be idempotent. On the first run it migrates state. On subsequent runs it detects the existing bucket and initializes directly against S3. Implement this with a `terraform init` that specifies the backend config — if the bucket already exists, `init` succeeds; if not, the workflow re-runs the local-first path.

### 1.2 S3 State Bucket

```hcl
resource "aws_s3_bucket" "terraform_state" {
  bucket = "<prefix>-terraform-state"

  lifecycle {
    prevent_destroy = true  # Both Bootstrap and Main state live here.
                            # Destroying this bucket destroys everything.
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Bucket policy: deny all requests where `aws:SecureTransport = false`.

State key layout:

- Bootstrap state: `bootstrap/terraform.tfstate`
- Main state: `main/terraform.tfstate`

### 1.3 ECR Repositories

Create all three repositories in Bootstrap. They must exist before Jenkins builds any image.

- `<prefix>-frontend`
- `<prefix>-backend`

For both:

- `image_tag_mutability = "IMMUTABLE"` — prevents tag overwrite
- `scan_on_push = true`
- Lifecycle policy: expire untagged images after 30 days, keep last 10 tagged images

No dedicated runner image repository — ARC is not used in this architecture.

### 1.4 VPC Public Layer

- VPC: your standard CIDR (e.g. `10.0.0.0/16`)
- Two public subnets, one per AZ — EKS and RDS require at least 2 AZs
- Internet Gateway attached to the VPC
- Public subnet route tables: `0.0.0.0/0` → IGW

This is the minimal public layer. Private subnets, NAT Gateway, and VPC endpoints are created in Phase 2 (Main) by Jenkins.

### 1.5 Jenkins EC2 Instance

**Placement:** Public subnet. Jenkins must reach the internet to clone from GitHub, call AWS APIs, and communicate with SSM public endpoints — all without a NAT Gateway or VPC endpoints during Bootstrap. A public IP provides this outbound connectivity.

**Security Group:** Zero ingress rules. Not port 22. Not port 8080. Nothing. All human access is exclusively through AWS Systems Manager Session Manager.

**Instance configuration:**

- AMI: Amazon Linux 2023 or Ubuntu 22.04+ (SSM agent pre-installed)
- No SSH key pair attached — omit entirely
- IMDSv2 only: `http_tokens = "required"`
- IAM instance profile: see Jenkins IAM below
- Tag: `Name = <prefix>-jenkins`, `Role = orchestrator`

**User-data script** must install and configure:

- Jenkins (LTS) and all required plugins
- Terraform 1.10+
- Ansible
- kubectl
- helm
- AWS CLI v2
- A seed job that triggers the Main phase pipeline on first boot

Jenkins should be ready to run the Main pipeline without any manual GUI interaction.

### 1.6 Jenkins IAM Role

**Trust policy:** EC2 service principal only.

**Attached policies:**

- `AmazonSSMManagedInstanceCore` — mandatory for SSM access
- Custom policy for Terraform Main operations: VPC, EKS, RDS, IAM, S3, EC2, SSM Parameter Store
- Custom policy for ECR: full push/pull on the `<prefix>-frontend` and `<prefix>-backend` repos
- Custom policy for S3 state: `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the state bucket only

**Permission boundary (mandatory):** Apply a permission boundary to the Jenkins role that caps the maximum permissions it can use or grant. This prevents a compromised Jenkins instance from escalating IAM privileges or creating resources outside the intended scope. The boundary should:

- Allow only the AWS services used by this project
- Deny `iam:CreateUser`, `iam:AttachUserPolicy`, `iam:PutUserPolicy`
- Deny actions on resources outside your naming prefix

**No static credentials, no access keys.** Terraform and Ansible on Jenkins pick up credentials automatically via the EC2 instance metadata service (IMDSv2).

### 1.7 Bootstrap GitHub Actions Workflow

```yaml
name: Bootstrap Infrastructure
on:
  workflow_dispatch:  # Manual trigger only — never on push

permissions:
  id-token: write
  contents: read

jobs:
  bootstrap:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<account>:role/<prefix>-github-bootstrap-role
          aws-region: <region>

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~1.10"

      - name: Detect first run vs subsequent run
        id: detect
        run: |
          if aws s3 ls s3://<prefix>-terraform-state/bootstrap/terraform.tfstate 2>/dev/null; then
            echo "mode=remote" >> $GITHUB_OUTPUT
          else
            echo "mode=local" >> $GITHUB_OUTPUT
          fi

      - name: Init (local — first run only)
        if: steps.detect.outputs.mode == 'local'
        run: terraform -chdir=terraform/bootstrap init

      - name: Apply (first run — creates bucket)
        if: steps.detect.outputs.mode == 'local'
        run: terraform -chdir=terraform/bootstrap apply -auto-approve

      - name: Migrate state to S3 (first run only)
        if: steps.detect.outputs.mode == 'local'
        run: |
          # Write backend config then migrate
          terraform -chdir=terraform/bootstrap init -migrate-state -force-copy

      - name: Init (remote — subsequent runs)
        if: steps.detect.outputs.mode == 'remote'
        run: terraform -chdir=terraform/bootstrap init

      - name: Plan and apply (subsequent runs)
        if: steps.detect.outputs.mode == 'remote'
        run: |
          terraform -chdir=terraform/bootstrap plan
          terraform -chdir=terraform/bootstrap apply -auto-approve
```

**OIDC trust policy for the Bootstrap GitHub Actions role — pin exactly:**

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:ref:refs/heads/main",
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    }
  }
}
```

Never use a wildcard (`*`) in the sub condition.

### 1.8 Bootstrap Verification

After the workflow completes:

- [ ] S3 bucket exists, versioning enabled, public access blocked
- [ ] State file present at `s3://<prefix>-terraform-state/bootstrap/terraform.tfstate`
- [ ] ECR repositories exist with immutable tags and lifecycle policies
- [ ] VPC exists with two public subnets and an Internet Gateway
- [ ] Jenkins instance shows Online in AWS Systems Manager → Fleet Manager
- [ ] Jenkins web UI reachable via SSM port forwarding (see Access Patterns)

---

## Phase 2: Main Infrastructure

Executed by: **Jenkins** (triggered manually or by SCM polling on the infrastructure repo)

Jenkins is in the same VPC as all private resources. It reaches the private EKS API endpoint, RDS, and the jump server via VPC routing — no internet path, no NAT traversal needed.

### 2.1 Main Terraform Backend

```hcl
terraform {
  backend "s3" {
    bucket       = "<prefix>-terraform-state"
    key          = "main/terraform.tfstate"
    region       = "<region>"
    use_lockfile = true
    encrypt      = true
  }
  required_version = ">= 1.10"
}
```

### 2.2 Terraform Stage — Network

**Private subnets:**

- One per AZ, larger CIDRs than public subnets (e.g. `10.0.10.0/24`, `10.0.11.0/24`)
- No direct route to the Internet Gateway
- All workloads live here: EKS nodes, RDS, jump server

**NAT Gateway:**

- One per AZ (two total) for high availability
- Placed in the public subnets
- Private subnet route tables: `0.0.0.0/0` → NAT Gateway
- Required for: EKS node outbound traffic, OS updates, SSM agent on private instances

**VPC endpoints:**

Required (cluster will not function without these):

|Endpoint|Type|Purpose|
|---|---|---|
|S3|Gateway (free)|ECR image layer storage, Terraform state access|
|ECR API|Interface|`ecr:GetAuthorizationToken` and API calls|
|ECR DKR|Interface|Docker registry protocol for image pulls|
|STS|Interface|IRSA token exchange without internet|
|SSM|Interface|SSM agent on jump server (private subnet)|
|SSMMessages|Interface|SSM data channel|
|EC2Messages|Interface|SSM agent communication|
|CloudWatch Logs|Interface|Container and SSM session logs stay internal|

All interface endpoints: Security Group must allow TCP 443 inbound from the VPC CIDR. Associate interface endpoints with the private subnet route tables.

### 2.3 Terraform Stage — EKS Cluster

```hcl
resource "aws_eks_cluster" "main" {
  name     = "<prefix>-cluster"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    endpoint_public_access  = false   # Private only — no public API endpoint
    endpoint_private_access = true
    subnet_ids              = [private_subnet_a_id, private_subnet_b_id]

    # Allow Jenkins (public subnet) to reach the private API endpoint
    security_group_ids = [aws_security_group.eks_additional.id]
  }

  # Enable OIDC at creation — cannot be added later without cluster recreation
  # The OIDC provider is created as a separate resource referencing this cluster's
  # OIDC issuer URL. Do this immediately after cluster creation.
}
```

**EKS cluster Security Group rules:**

The EKS cluster Security Group must explicitly allow TCP 443 from the Jenkins Security Group. Jenkins is in the public subnet but in the same VPC, so VPC routing handles delivery.

```hcl
resource "aws_security_group_rule" "eks_from_jenkins" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.jenkins.id  # Jenkins SG ID — tightest scope
  security_group_id        = aws_security_group.eks_cluster.id
  description              = "Jenkins Terraform and Ansible access to EKS API"
}
```

Also allow the jump server SG on 443 for human debugging.

**Managed node groups:**

- Deploy into private subnets
- Node IAM role: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`
- Security Group: allow ingress from EKS control plane SG on 443 and 10250

**EKS add-ons (create at cluster time):**

- `vpc-cni` with IRSA enabled for the CNI service account
- `coredns`
- `kube-proxy`
- `aws-ebs-csi-driver` — required for PVCs (ArgoCD, Grafana, Prometheus, Loki)

**OIDC provider:** Create immediately after cluster creation. This is mandatory for IRSA. Reference the cluster's OIDC issuer URL as a data source — do not hard-code it.

### 2.4 Terraform Stage — RDS

- Subnet group: private subnets
- `publicly_accessible = false`
- Encryption at rest: enabled
- Automated backups: 7-day retention minimum
- Maintenance window: define a low-traffic period

**Security Group — strict rules:**

- Ingress: from EKS node Security Group on the DB port only
- No ingress from the jump server — access is via ephemeral pods or SSM port-forward only
- No ingress from Jenkins — Jenkins has no application-level DB access

### 2.5 Terraform Stage — Jump Server

**Placement:** Private subnet (unlike Jenkins, the jump server has no need for outbound internet — all AWS API calls go through VPC endpoints).

**Security Group:** Zero ingress rules. All access via SSM through VPC endpoints.

**Instance configuration:**

- AMI: Amazon Linux 2023 or Ubuntu 22.04+
- No SSH key pair
- IMDSv2 only: `http_tokens = "required"`
- IAM instance profile: SSM + limited EKS read-only only
- Tag: `Name = <prefix>-jump-server`, `Role = human-access`

**Jump server IAM role:**

- `AmazonSSMManagedInstanceCore`
- Custom policy: `eks:DescribeCluster`, `eks:ListClusters` only
- No Terraform permissions, no ECR write, no broad admin — this instance is for human debugging only, never for automation

### 2.6 Ansible Stage — Platform Installation

Immediately after Terraform completes, Jenkins runs the Ansible playbook. Jenkins is already in the VPC and can reach the private EKS endpoint directly.

**Kubeconfig handling on Jenkins:**

```bash
# Generate a temporary kubeconfig in the Jenkins workspace
aws eks update-kubeconfig \
  --region <region> \
  --name <prefix>-cluster \
  --kubeconfig ${WORKSPACE}/kubeconfig/eks-config.yaml

# All kubectl and Ansible calls reference this path explicitly
export KUBECONFIG=${WORKSPACE}/kubeconfig/eks-config.yaml

# Jenkins pipeline post-step (always block): delete it
rm -f ${WORKSPACE}/kubeconfig/eks-config.yaml
```

Never write to `~/.kube/config` on Jenkins. Multiple pipeline builds may run concurrently. The workspace-scoped path prevents collisions.

**Ansible installs in this order:**

1. **ArgoCD** — GitOps control plane. Install via `kubernetes.core.k8s` with server-side apply. Pin the version (e.g. v2.11.x). Verify all pods are Running before proceeding.
    
2. **Prometheus** — metrics collection. Install via the `kube-prometheus-stack` Helm chart. This chart also includes the Prometheus Operator and Alertmanager.
    
3. **Grafana** — dashboards. Installed as part of `kube-prometheus-stack` by default, or separately if you need more control over the version and configuration.
    
4. **Loki** — log aggregation. Install via Helm (`grafana/loki-stack`).
    
5. **Promtail** — log shipper. Deployed as a DaemonSet on all nodes, installed as part of the `loki-stack` chart. Verify a Promtail pod exists on every node after installation.
    

**Post-install verification (Jenkins pipeline step):**

```bash
kubectl --kubeconfig ${WORKSPACE}/kubeconfig/eks-config.yaml \
  get pods -n argocd -o wide
kubectl --kubeconfig ${WORKSPACE}/kubeconfig/eks-config.yaml \
  get pods -n monitoring -o wide
kubectl --kubeconfig ${WORKSPACE}/kubeconfig/eks-config.yaml \
  get pods -n logging -o wide
# All pods must be Running/Ready before the pipeline marks success
```

**Cleanup (always block — runs even on failure):**

```bash
rm -f ${WORKSPACE}/kubeconfig/eks-config.yaml
```

### 2.7 Main Verification

After Jenkins completes both stages:

- [ ] EKS cluster Active, all nodes Ready
- [ ] RDS available, not publicly accessible
- [ ] VPC interface endpoints active, Security Groups configured
- [ ] ArgoCD pods Running in `argocd` namespace
- [ ] Prometheus and Grafana pods Running in `monitoring` namespace
- [ ] Loki and Promtail pods Running in `logging` namespace, Promtail DaemonSet covers all nodes
- [ ] Jump server Online in SSM Fleet Manager
- [ ] Jump server can reach EKS API: `kubectl --kubeconfig /tmp/eks-jump.yaml get nodes`

---

## Phase 3: Application Delivery

Executed by: **GitHub Actions** (push to application repos) GitHub-hosted runners stay entirely on the public side — they never touch the VPC.

### 3.1 How It Works

```
Developer pushes code
       ↓
GitHub Actions (public runner)
  1. Build Docker image
  2. Push to ECR (public AWS API endpoint)
  3. Checkout GitOps repo
  4. Update image tag in manifests/values
  5. Commit and push to GitOps repo
       ↓
ArgoCD (inside private VPC)
  - Detects drift between Git and cluster state
  - Pulls new image from ECR via VPC endpoint
  - Applies updated manifests to the cluster
  - Reports sync status
```

GitHub Actions never calls `kubectl`. ArgoCD never exposes the cluster to GitHub Actions. The boundary is Git — GitHub Actions writes to Git, ArgoCD reads from Git.

### 3.2 Application CI Workflow

```yaml
name: Application CI
on:
  push:
    branches: [main]
  pull_request:

permissions:
  id-token: write
  contents: write  # Required to commit back to the GitOps repo

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<account>:role/<prefix>-github-app-role
          aws-region: <region>

      - name: Login to ECR
        run: |
          aws ecr get-login-password --region <region> | \
          docker login --username AWS --password-stdin \
            <account>.dkr.ecr.<region>.amazonaws.com

      - name: Build and push
        run: |
          IMAGE_TAG="${GITHUB_SHA::8}"
          docker build -t <account>.dkr.ecr.<region>.amazonaws.com/<prefix>-frontend:${IMAGE_TAG} .
          docker push <account>.dkr.ecr.<region>.amazonaws.com/<prefix>-frontend:${IMAGE_TAG}
          echo "IMAGE_TAG=${IMAGE_TAG}" >> $GITHUB_ENV

      - name: Checkout GitOps repo
        uses: actions/checkout@v4
        with:
          repository: <org>/gitops-repo
          path: gitops
          token: ${{ secrets.GITOPS_PAT }}

      - name: Update image tag
        run: |
          sed -i "s|tag:.*|tag: ${IMAGE_TAG}|g" gitops/apps/frontend/values.yaml
          cd gitops
          git config user.email "ci@github-actions"
          git config user.name "GitHub Actions"
          git add apps/frontend/values.yaml
          git commit -m "ci: update frontend to ${IMAGE_TAG}"
          git push
      # ArgoCD detects the commit and syncs — workflow ends here
```

### 3.3 GitHub Actions IAM Role (Application)

**Trust policy:** pin to the exact application repo and branch:

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:sub": "repo:<org>/<app-repo>:ref:refs/heads/main",
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    }
  }
}
```

**Permissions:**

- `ecr:GetAuthorizationToken` (account-level)
- `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage` — scoped to the specific ECR repo ARNs only

No VPC access. No EKS permissions. No RDS permissions.

---

## Access Patterns

No SSH anywhere. All human access is through AWS Systems Manager.

### Accessing Jenkins

```bash
aws ssm start-session \
  --target <jenkins-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
# Browse to http://localhost:8080
```

### Accessing the Jump Server

```bash
aws ssm start-session --target <jump-server-instance-id>

# Inside the session:
aws eks update-kubeconfig \
  --region <region> \
  --name <prefix>-cluster \
  --kubeconfig /tmp/eks-jump.yaml

kubectl --kubeconfig /tmp/eks-jump.yaml get nodes
kubectl --kubeconfig /tmp/eks-jump.yaml get pods -A

# Always delete before ending the session:
rm /tmp/eks-jump.yaml
```

### Accessing ArgoCD / Grafana / Prometheus UI

This requires two terminal windows:

**Terminal 1 — port-forward inside the cluster (from jump server SSM session):**

```bash
# In your SSM session on the jump server:
kubectl --kubeconfig /tmp/eks-jump.yaml \
  port-forward svc/argocd-server -n argocd 8080:443
# Leave this running
```

**Terminal 2 — tunnel from laptop to jump server:**

```bash
# From your laptop:
aws ssm start-session \
  --target <jump-server-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
# Browse to https://localhost:8080
```

Replace port and service name for Grafana (`3000`), Prometheus (`9090`), Loki as needed.

### Accessing RDS

**Option A — SSM port-forward tunnel (no cluster required):**

```bash
aws ssm start-session \
  --target <jump-server-instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<rds-endpoint>"],"portNumber":["5432"],"localPortNumber":["5432"]}'
# Connect your DB client to localhost:5432
```

**Option B — ephemeral database pod (from jump server):**

```bash
kubectl --kubeconfig /tmp/eks-jump.yaml run db-debug \
  --image=postgres:15 --rm -it --restart=Never \
  -- psql -h <rds-endpoint> -U <user> -d <database>
# Pod is deleted automatically when you exit
```

---

## Day-2 Operations

### Terraform State

Both Bootstrap and Main state are in S3 with native locking. If a lock gets stuck (Terraform process killed mid-run), the lock object is a `.tflock` file alongside the state key.

```bash
# Identify the stuck lock
aws s3 ls s3://<prefix>-terraform-state/main/

# Remove it ONLY after confirming no Terraform process is running
aws s3 rm s3://<prefix>-terraform-state/main/terraform.tfstate.tflock
```

Never force-unlock during an active apply.

### ArgoCD

ArgoCD is self-healing. Cluster drift from Git state is resynced automatically. For manual sync or investigation:

```bash
# From jump server
kubectl --kubeconfig /tmp/eks-jump.yaml get applications -n argocd
kubectl --kubeconfig /tmp/eks-jump.yaml describe application <app-name> -n argocd
```

Or use the ArgoCD UI via the two-terminal tunnel above.

### Jenkins

- UI access: SSM port-forward to port 8080
- Logs: SSM session directly on the instance, `sudo journalctl -u jenkins`
- Backup: snapshot the Jenkins EBS volume before any infrastructure changes
- If Jenkins is lost: re-run Bootstrap workflow, restore EBS snapshot or recreate jobs

Jenkins is a pet. Treat its EBS volume accordingly.

### EKS Upgrades

- Control plane: update via Terraform (`version` field on the cluster resource)
- Node groups: managed rolling upgrade by EKS after control plane is updated
- Verify: `kubectl get nodes` and `kubectl get pods -A` after each upgrade

### Patching

- Jenkins: SSM session + `sudo dnf update -y` (Amazon Linux) or AWS SSM Patch Manager
- Jump server: same, monthly
- EKS nodes: rolling node group upgrade handles this

---

## Troubleshooting

### SSM Connection Fails

- Verify SSM agent is running: `sudo systemctl status amazon-ssm-agent`
- Jenkins (public subnet): verify instance profile has `AmazonSSMManagedInstanceCore`
- Jump server (private subnet): additionally verify SSM, SSMMessages, EC2Messages VPC endpoints exist and their Security Groups allow TCP 443 from the VPC CIDR
- Verify your IAM user/role has `ssm:StartSession` permission

### Jenkins Cannot Reach EKS API

- Verify Jenkins Security Group is the source in the EKS SG rule on port 443
- Verify the EKS cluster SG rule references the Jenkins SG ID (not CIDR)
- Run from Jenkins: `curl -k https://<eks-private-endpoint>` — should return 403, not timeout
- Check VPC route tables: Jenkins (public subnet) → private subnet → EKS control plane ENIs

### Ansible Fails to Connect to EKS

- Verify kubeconfig was generated correctly: `aws eks update-kubeconfig` exit code 0
- Verify KUBECONFIG env var points to the workspace-scoped path
- Verify the Jenkins IAM role is in the EKS access entries or `aws-auth` ConfigMap

### ArgoCD Not Syncing

- Check Application status: `kubectl get app -n argocd`
- Common causes: Git repo credential expired, image not found in ECR, resource quota exceeded
- Force sync: `kubectl -n argocd patch app <name> -p '{"operation":{"sync":{}}}' --type merge`

### ARC-Related Issues

ARC is not used in this architecture. GitHub-hosted runners handle all CI. If you see references to ARC in old configs, remove them.

### ECR Pull Fails from EKS Nodes

- Verify node IAM role has `AmazonEC2ContainerRegistryReadOnly`
- Verify ECR API and ECR DKR VPC endpoints are active and associated with private subnets
- Verify the S3 Gateway endpoint is attached to private subnet route tables (ECR image layers are stored in S3)

### RDS Connection Fails from Application Pods

- Verify RDS Security Group allows ingress from EKS node SG on the DB port
- Verify RDS subnet group spans the same AZs as the EKS nodes
- Use Option B (ephemeral pod) from Access Patterns to test connectivity manually

### S3 State Lock Stuck

See Day-2 Operations → Terraform State above.

---

## Security Notes

**Jenkins IAM permission boundary:** Applied to the Jenkins role. Caps maximum permissions regardless of what policies are attached. Prevents a compromised Jenkins from escalating IAM privileges or creating out-of-scope resources. Review and tighten the boundary after initial build when the exact permissions needed are known.

**OIDC trust policies:** All GitHub Actions roles pin the exact `repo:org/repo:ref:refs/heads/main` condition. Wildcards are not acceptable. Separate roles exist for Bootstrap and application CI.

**No static credentials anywhere:** Jenkins uses EC2 instance profile via IMDSv2. GitHub Actions uses OIDC assumed roles. No access keys, no secrets in environment variables.

**IMDSv2 enforced:** All EC2 instances (Jenkins, jump server) have `http_tokens = "required"`. This prevents SSRF attacks from using the metadata service to steal credentials.

**No SSH anywhere:** Zero key pairs, zero port 22 ingress rules on any Security Group. All human and automation access is via SSM or VPC routing.

**ArgoCD as the only cluster mutator:** After initial Ansible installation, only ArgoCD should apply manifests to the cluster. No `kubectl apply` from pipelines or humans for routine changes. Use Git — ArgoCD reconciles.