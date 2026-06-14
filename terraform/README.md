# ShopVerse - Terraform Infrastructure

Provision the complete AWS infrastructure for ShopVerse from your local machine using Terraform modules.

## What Gets Created

| Resource | Module | Description |
|----------|--------|-------------|
| VPC | `modules/vpc` | VPC, 2 public subnets, 2 private subnets, IGW, NAT Gateway, route tables |
| EKS Cluster | `modules/eks` | EKS control plane, managed node group, OIDC provider, EBS CSI driver addon |
| IAM Roles | `modules/eks` | Cluster role, node role, ALB controller role, EBS CSI role |
| Jump Server | `modules/ec2` | Ubuntu 22.04 EC2 with kubectl, helm, docker pre-installed |

## Prerequisites

Install the following tools on your local machine:

```bash
# 1. Terraform (>= 1.10.0)
#    Download: https://developer.hashicorp.com/terraform/downloads

# 2. AWS CLI v2
#    Download: https://aws.amazon.com/cli/

# 3. kubectl
#    Download: https://kubernetes.io/docs/tasks/tools/

# 4. Helm 3
#    Download: https://helm.sh/docs/intro/install/
```

## Step 1: Configure AWS CLI

```bash
aws configure
# AWS Access Key ID: <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region name: us-east-1
# Default output format: json

# Verify
aws sts get-caller-identity
```

## Step 2: Bootstrap Infrastructure (One-time setup)

The bootstrap module creates the S3 state bucket and ECR repositories automatically.

```bash
cd bootstrap
terraform init
terraform apply -auto-approve -var-file="../terraform.tfvars"
./migrate.sh
cd ..
```

**Note:** Because the bootstrap module is in a separate directory, it cannot read `terraform.tfvars` from the parent automatically. Use `-var-file="../terraform.tfvars"` to share the project configuration.

## Step 3: Configure Variables

```bash
# Copy the example file
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
aws_region   = "us-east-1"
project_name = "shopverse"

# VPC
vpc_cidr = "10.0.0.0/16"

# EKS
cluster_name       = "shopverse-cluster"
cluster_version    = "1.29"
node_instance_type = "t3.medium"
node_desired_size  = 2
node_min_size      = 1
node_max_size      = 4

# Jump Server
create_jump_server        = true
jump_server_instance_type = "t2.medium"
```

Set `create_jump_server = false` if you don't need a jump server.

## Step 4: Initialize Terraform

```bash
cd terraform

terraform init
```

If using S3 backend with different bucket/region:

```bash
terraform init \
  -backend-config="bucket=my-custom-bucket" \
  -backend-config="key=eks/terraform.tfstate" \
  -backend-config="region=us-east-1"
```

## Step 5: Plan and Review

```bash
terraform plan
```

Review the output carefully. It will show all resources to be created.

## Step 6: Apply

```bash
terraform apply
```

Type `yes` when prompted. This takes approximately 15-20 minutes (EKS cluster creation is the slowest part).

## Step 7: Connect to the EKS Cluster

After `terraform apply` completes, it outputs the kubeconfig command:

```bash
# Copy the kubeconfig command from terraform output
aws eks update-kubeconfig --name shopverse-cluster --region us-east-1

# Verify connection
kubectl get nodes
kubectl cluster-info
```

## Step 8: Connect to the Jump Server

Go to AWS Console > EC2 > Instances > Select the jump server > Click **Connect** > Use **EC2 Instance Connect**.

The jump server comes pre-installed with:
- AWS CLI v2
- kubectl (with kubeconfig already configured)
- Helm 3
- Docker
- Git

Once connected:

```bash
# Verify kubectl is working
kubectl get nodes

# Verify helm
helm version

# Check cluster pods
kubectl get pods -A
```

## Terraform Outputs

After apply, view all outputs:

```bash
terraform output
```

| Output | Description |
|--------|-------------|
| `vpc_id` | VPC ID |
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | EKS API server endpoint |
| `alb_controller_role_arn` | IAM role ARN for ALB controller |
| `ebs_csi_role_arn` | IAM role ARN for EBS CSI driver |
| `jump_server_public_ip` | Jump server public IP |
| `jump_server_instance_id` | Jump server EC2 instance ID |
| `jump_server_console_url` | Direct link to connect via AWS Console |
| `kubeconfig_command` | Command to configure kubectl |

## Deploy ShopVerse Application

After the infrastructure is ready:

```bash
# 1. Login to ECR
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

# 2. Application Deployment (GitOps Flow)

The application deployment is now decoupled from infrastructure using a GitOps pattern.

- **App Source Code**: Located in `app-repo`. Push here to trigger Jenkins build and ECR push.
- **K8s Configuration**: Located in `k8s-config-repo`. ArgoCD monitors this repo for changes.

**Manual First-Time Deployment:**
If you need to deploy for the first time manually:
1. Build and push images from `app-repo`.
2. Update image tags in `k8s-config-repo/helm/shopverse/values.yaml`.
3. ArgoCD will automatically sync the change to the cluster.

# 4. Install ALB controller
ALB_ROLE_ARN=$(cd terraform && terraform output -raw alb_controller_role_arn)
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=shopverse-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_ROLE_ARN


# 6. Verify
kubectl get pods -n shopverse
kubectl get svc -n shopverse
```

## Modify Infrastructure

To change any resource (e.g., scale nodes, change instance type):

```bash
# Edit terraform.tfvars
# Example: change node_desired_size = 3

terraform plan    # Review changes
terraform apply   # Apply changes
```

## Destroy Infrastructure

To tear down everything:

```bash
# First, delete Kubernetes resources (Helm release, PVCs, etc.)
helm uninstall shopverse -n shopverse
kubectl delete pvc --all -n shopverse
kubectl delete namespace shopverse

# Then destroy Terraform-managed infrastructure
terraform destroy
```

Type `yes` when prompted. This removes all AWS resources created by Terraform.

> **Warning:** `terraform destroy` will delete the EKS cluster, VPC, jump server, and all associated resources. Make sure you have backed up any important data.

## Module Structure

```
terraform/
├── main.tf                       # Root - wires all modules together
├── variables.tf                  # Root input variables
├── outputs.tf                    # Root outputs from all modules
├── versions.tf                   # Provider versions + S3 backend
├── terraform.tfvars.example      # Example variable values
└── modules/
    ├── vpc/
    │   ├── main.tf               # VPC, subnets, IGW, NAT, route tables
    │   ├── variables.tf          # name, vpc_cidr, cluster_name
    │   └── outputs.tf            # vpc_id, public/private subnet IDs
    ├── eks/
    │   ├── main.tf               # Cluster, node group, OIDC, ALB role, EBS CSI
    │   ├── variables.tf          # cluster config, node config
    │   └── outputs.tf            # endpoints, role ARNs, OIDC
    └── ec2/
        ├── main.tf               # Ubuntu EC2, IAM role, security group
        ├── userdata.sh           # Bootstraps kubectl, helm, docker
        ├── variables.tf          # instance_type, cluster_name
        └── outputs.tf            # public_ip, instance_id, console URL
```

## Troubleshooting

### Terraform init fails with S3 backend error
```bash
# Make sure the S3 bucket exists (see Step 2)
# Or remove the backend block from versions.tf to use local state
```

### EKS cluster creation times out
```bash
# EKS takes ~15 minutes. If it times out, just run again:
terraform apply
```

### Jump server userdata didn't run
```bash
# Check cloud-init logs after connecting
sudo cat /var/log/cloud-init-output.log
```

### kubectl can't connect from jump server
```bash
# Re-run kubeconfig setup
aws eks update-kubeconfig --name shopverse-cluster --region us-east-1

# Verify IAM role has permissions
aws sts get-caller-identity
```

### Nodes not joining the cluster
```bash
# Check node group status
aws eks describe-nodegroup \
  --cluster-name shopverse-cluster \
  --nodegroup-name shopverse-cluster-nodes \
  --region us-east-1 \
  --query 'nodegroup.status'
```
