# Shopverse Infrastructure Documentation

## Workflow Overview

The Shopverse infrastructure follows a **three-phase deployment workflow**:

1. **Phase 1 - Bootstrap**: Creates foundational resources (S3 state bucket, ECR repos, VPC with public subnets, bastion host) and GitHub OIDC roles
2. **Phase 2 - Main Infrastructure**: Deploys EKS cluster, private networking, and RDS database using the bootstrap VPC
3. **Phase 3 - Platform Services**: Installs Kubernetes add-ons (ALB controller, External Secrets, ArgoCD, monitoring) via Ansible

---

## Phase 1: Bootstrap (`/terraform/bootstrap/`)

### What It Does

The bootstrap phase creates all foundational AWS resources required for the complete infrastructure lifecycle. It establishes the state storage backend, container registry, network foundation, and IAM roles for subsequent automation.

### How It Works

1. **Initial State Management**: Uses `backend "local"` temporarily to avoid chicken-and-egg dependency
2. **State Migration**: After applying, `migrate.sh` rewrites `backend.tf` to use S3 and migrates local state
3. **Outputs provide values** for main infrastructure (VPC ID, subnet IDs, role ARNs)

### Resources Created

#### S3 State Bucket (`aws_s3_bucket.tfstate`)
- **Purpose**: Remote Terraform state storage with encryption and versioning
- **Why Created**: Enables collaborative Terraform workflows, state locking, and state history
- **Configuration**:
  - Versioning enabled for rollback capability
  - AES256 encryption at rest
  - Public access blocked for security
  - `prevent_destroy` lifecycle to avoid accidental deletion

#### ECR Repositories (`aws_ecr_repository.repos`)
- **Purpose**: Container image registry for frontend and backend services
- **Why Created**: Immutable tags prevent overwrites; scanning on push ensures security
- Lifecycle policy: Keeps last 10 untagged images, expires older ones

#### VPC (`aws_vpc.main`)
- **Purpose**: Isolated network (CIDR: 10.0.0.0/16) with DNS support
- **Why Created**: Provides network isolation; DNS hostnames required for EKS

#### Public Subnets (`aws_subnet.public`)
- **Purpose**: Two public subnets across availability zones
- **Why Created**: Hosts bastion EC2 with public IP access; ALB needs public subnets

#### Internet Gateway (`aws_internet_gateway.igw`)
- **Purpose**: Provides outbound internet access to public subnets
- **Why Created**: Required for bastion SSH access and ECR image pulls

#### Route Table (`aws_route_table.public`)
- **Purpose**: Routes all traffic (0.0.0.0/0) through IGW
- **Why Created**: Enables internet egress for resources in public subnets

#### Bastion Security Group (`aws_security_group.bastion`)
- **Purpose**: Restricts SSH (port 22) to configured CIDR blocks
- **Why Created**: Secure administrative access point; outbound all for AWS API/Git access

#### Bastion IAM Role (`aws_iam_role.bastion`)
- **Purpose**: EC2 instance profile for bastion host
- **Why Created**: Enables AWS API access for kubectl/eks commands
- **Permissions**:
  - `eks:DescribeCluster`, `eks:ListClusters`: Cluster discovery
  - `ecr:GetAuthorizationToken`: Docker authentication
  - `ec2:DescribeInstances`, `rds:DescribeDBInstances`: Resource inspection

#### Bastion EC2 (`aws_instance.bastion`)
- **Purpose**: Jump server for accessing private EKS cluster
- **Why Created**: EKS has private endpoint; bastion bridges CI/CD to cluster
- **Configuration**: t3.micro, gp3 20GB encrypted root volume, IMDSv2 enforced

#### GitHub OIDC Provider Data Source (`data.aws_iam_openid_connect_provider.github`)
- **Purpose**: References pre-existing GitHub OIDC identity provider
- **Why Created**: Enables GitHub Actions to assume AWS roles without long-lived credentials

#### Bootstrap Permission Boundary (`aws_iam_policy.bootstrap_boundary`)
- **Purpose**: Caps maximum permissions for the GitHub bootstrap role
- **Why Created**: Security control preventing privilege escalation beyond boundary
- **Denies**:
  - Boundary tampering (changing/deleting permission boundaries)
  - Privilege escalation (CreateAccessKey, CreateAccountAlias, UpdateAssumeRolePolicy)

#### Bootstrap Role (`aws_iam_role.github_bootstrap`)
- **Purpose**: GitHub Actions role for infrastructure deployment
- **Why Created**: Enables CI/CD to manage all AWS resources via OIDC
- **Trust Policy**: GitHub OIDC with condition matching `repo:org/repo:ref:refs/heads/branch`

#### Bootstrap Permissions Policy (`aws_iam_policy.bootstrap_permissions`)
- **Purpose**: Grants GitHub bootstrap role access to all required services
- **Why Created**: Single policy for bootstrap + main infrastructure management
- **Services**: s3, ecr, ec2, iam, elasticloadbalancing, cloudwatch, logs, kms, eks, rds, ssm, autoscaling, vpc, secretsmanager
- **Conditional**: Restricted to configured AWS region

#### GitHub App Role (`aws_iam_role.github_app`)
- **Purpose**: GitHub Actions role for application builds (ECR pushes)
- **Why Created**: Separate role for app pipeline with minimal ECR permissions only
- **Trust Policy**: GitHub OIDC for application repository
- **Permissions**: ECR read/write operations for frontend/backend repositories only

---

## Phase 2: Main Infrastructure (`/terraform/`)

### What It Does

Deploys the production Kubernetes cluster, private networking, and database. Uses the bootstrap VPC and creates private subnets, NAT gateway, and EKS with managed node groups.

### How It Works

1. **VPC Lookup**: References bootstrap VPC by name tag
2. **Private Subnets**: Creates isolated subnets for EKS nodes
3. **Private Data Subnets**: Dedicated subnets for RDS (isolation from compute)
4. **NAT Gateway**: Single AZ NAT for cost optimization (private subnets egress)
5. **EKS Cluster**: Private endpoint with bastion access
6. **RDS**: Multi-AZ MySQL with Secrets Manager integration

### Resources Created

#### VPC Module (`module.vpc`)
- **Inputs**: Existing VPC ID from bootstrap, CIDR block
- **Creates**:
  - **Private Subnets** (`aws_subnet.private`): Three subnets (10.0.32.0/20 to 10.0.47.0/20)
    - Why: Isolated placement for EKS worker nodes
    - User: `kubernetes.io/role/elb=1` tag for ALB discovery
  - **Private Data Subnets** (`aws_subnet.private_data`): Three subnets (10.0.96.0/20 to 10.0.111.0/20)
    - Why: Isolated placement for RDS; no direct EKS access
    - Tag: `Tier=data` for identification
  - **NAT Gateway** (`aws_nat_gateway.this`): Single gateway in bootstrap public subnet
    - Why: Cost optimization; private resources need outbound internet (ECR, updates)
  - **Route Tables** (`aws_route_table.private`): Routes 0.0.0.0/0 to NAT
  - **VPC Endpoints**:
    - S3 Gateway: Private S3 access without internet
    - Interface Endpoints (ECR API, ECR DKR, STS, CloudWatch Logs): Private endpoint access

#### EKS Module (`module.eks`)
- **Cluster IAM Role** (`aws_iam_role.cluster`):
  - Why: EKS control plane requires IAM role for AWS API calls
  - Attached Policies: `AmazonEKSClusterPolicy`, `AmazonEKSVPCResourceController`
- **Cluster Security Group** (`aws_security_group.cluster`):
  - Why: Custom SG for cluster control plane (default EKS-managed one also exists)
  - Egress all for node communication
- **EKS Cluster** (`aws_eks_cluster.this`):
  - Why: Managed Kubernetes control plane
  - Private endpoint only (public access disabled)
  - API_AND_CONFIG_MAP authentication with auto-admin for cluster creator
- **Node IAM Role** (`aws_iam_role.nodes`):
  - Why: EC2 instances need AWS permissions for CNI, EC2, ECR
  - Attached Policies: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`
- **EKS Managed Node Group** (`aws_eks_node_group.this`):
  - Why: Managed AMI updates, automated scaling
  - AL2023 AMI, m7i-flex.large instances, autoscaling group (1-4 nodes)
- **OIDC Provider** (`aws_iam_openid_connect_provider.eks`):
  - Why: Enables IRSA (IAM Roles for Service Accounts)
  - Service accounts get AWS permissions via OIDC trust
- **ALB Controller IRSA Role** (`aws_iam_role.alb_controller`):
  - Why: Kubernetes service creates AWS load balancers
  - Trust: `system:serviceaccount:kube-system:aws-load-balancer-controller`
  - Policy: `ElasticLoadBalancingFullAccess`
- **EBS CSI Driver IRSA Role** (`aws_iam_role.ebs_csi`):
  - Why: Provides persistent volumes via EBS
  - Trust: `system:serviceaccount:kube-system:ebs-csi-controller-sa`
  - Policy: `AmazonEBSCSIDriverPolicy` (added via `aws_iam_role_policy` for EC2 actions)
  - Addon: Installed as EKS managed addon
- **External Secrets IRSA Role** (`aws_iam_role.eso_irsa`):
  - Why: Syncs AWS Secrets Manager to Kubernetes secrets
  - Trust: `system:serviceaccount:external-secrets:external-secrets`
  - Policy: Read-only access to `shopverse/*` secrets

#### EKS Access Entry (`aws_eks_access_entry.bastion`)
- **Purpose**: Grants bastion host Kubernetes API access
- **Why Created**: Bastion needs to run kubectl/helm commands
- **Policy**: `AmazonEKSClusterAdminPolicy` (full cluster admin rights)

#### Security Group Rule (`aws_security_group_rule.eks_from_bastion`)
- **Purpose**: Allows bastion to reach EKS API on port 443
- **Why Created**: Private cluster endpoint requires explicit ingress rule

#### RDS Module (`module.rds`)
- **DB Subnet Group** (`aws_db_subnet_group.this`):
  - Why: Required for RDS; places in private data subnets
- **DB Security Group** (`aws_security_group.rds`):
  - Why: Isolated database access
  - Egress all for updates; ingress from EKS nodes via rule in main.tf
- **RDS Instance** (`aws_db_instance.this`):
  - Why: Managed MySQL database
  - Multi-AZ for high availability
  - db.t3.micro for cost efficiency (dev/staging scale)
  - Storage encrypted with gp3

#### Secrets Manager Secrets
- **`aws_secretsmanager_secret.db_credentials`**:
  - Why: Secure database credentials for applications
  - Scope: `shopverse/*` for ESO access
- **`aws_secretsmanager_secret.jwt_secret`**:
  - Why: Secure JWT signing key for application auth
  - Scope: `shopverse/*` for ESO access

---

## Phase 3: Ansible Platform Services (`/ansible/`)

### What It Does

Deploys Kubernetes platform services via Helm from the bastion host. These services provide ingress, secret synchronization, GitOps, and observability capabilities.

### How It Works

1. **Execution**: Runs on bastion (localhost via Ansible)
2. **kubeconfig**: Updated via `aws eks update-kubeconfig`
3. **Helm Charts**: Installed from official repositories with IRSA service accounts
4. **Verification**: Waits for deployments to become ready before completing

### Roles

#### ALB Controller (`roles/alb_controller/tasks/main.yml`)
- **Purpose**: AWS Load Balancer Controller for Kubernetes ingress
- **Why Created**: Automatically provisions ALBs for Ingress resources
- **Helm Values**:
  - `clusterName`: EKS cluster name for resource tagging
  - `serviceAccount.annotations`: IRSA role ARN for AWS permissions
- **Installed in**: `kube-system` namespace

#### External Secrets (`roles/external-secrets/tasks/main.yml`)
- **Purpose**: External Secrets Operator for secret synchronization
- **Why Created**: Sync AWS Secrets Manager secrets to Kubernetes secrets
- **Actions**:
  - Checks if release exists; only installs if missing
  - Creates CRDs on first install
  - Waits for CRD registration
  - Applies `ClusterSecretStore` for AWS Secrets Manager integration

#### ArgoCD (`roles/argocd/tasks/main.yml`)
- **Purpose**: GitOps continuous delivery
- **Why Created**: Declarative application deployment via Git
- **Configuration**: Chart version 9.5.20, installed in `argocd` namespace
- **Creates kubeconfig** on bastion for subsequent roles

#### Monitoring (`roles/monitoring/tasks/main.yml`)
- **Purpose**: Prometheus + Grafana for observability
- **Why Created**: Platform monitoring and alerting
- **Helm Values**:
  - Grafana enabled with ClusterIP service
  - Prometheus retention: 10 days

---

## Deployment Flow Summary

```
┌─────────────────────────────────────────────────────────────┐
│                   Local Machine (Developer)                │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: Bootstrap                                           │
│  - terraform init/apply                                       │
│  - Creates: S3, ECR, VPC (public), Bastion, IAM roles         │
│  - migrate.sh → move state to S3                             │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  Phase 2: Main Infrastructure                                 │
│  - terraform init/apply (from /terraform/)                    │
│  - Uses bootstrap VPC                                         │
│  - Creates: Private subnets, NAT, EKS, RDS, Secrets           │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  Phase 3: Platform Services (via Ansible on Bastion)           │
│  - ansible-playbook site.yml                                    │
│  - Installs: ALB Controller, External Secrets, ArgoCD, Prom  │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  Phase 4: Application Delivery (GitHub Actions, OIDC)          │
│  - Pushes to ECR via github_app role                             │
│  - ArgoCD syncs from gitops repo                                 │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Security Controls

### Permission Boundaries
- **Bootstrap Boundary**: Limits GitHub bootstrap role to prevent escalation
- **IRSA Roles**: Each service has minimal required permissions (ALB, EBS, ESO)

### Network Security
- **Bastion**: SSH-restricted security group
- **EKS**: Private API endpoint with bastion-only access
- **RDS**: Private subnet with EKS node ingress only

### State Security
- **S3 Encryption**: AES256 server-side encryption
- **State Locking**: Native S3 locking (no DynamoDB required)
- **Versioning**: Enabled for recovery capability

### Secrets Management
- **Secrets Manager**: All credentials stored encrypted
- **Zero retention**: `recovery_window_in_days = 0` for immediate deletion
- **ESO Integration**: Applications access via Kubernetes secrets, not AWS SDK