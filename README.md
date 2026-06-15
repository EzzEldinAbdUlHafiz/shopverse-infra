# ShopVerse Infrastructure

Infrastructure-as-Code for the ShopVerse e-commerce platform. Deploys a complete AWS infrastructure stack including VPC, EKS cluster, RDS, and GitOps platform services.

## Architecture Overview

```
shopverse-infra/
├── terraform/                 # Infrastructure modules
│   ├── main.tf                # Root - wires all modules together
│   ├── modules/
│   │   ├── ecr/             # ECR repositories
│   │   ├── eks/             # EKS cluster + node groups
│   │   ├── rds/             # MySQL database
│   │   ├── ec2/             # Bastion/jump server
│   │   └── vpc/             # VPC, subnets, NAT gateway
│   └── bootstrap/             # One-time setup (S3 state bucket, ECR repos, Jenkins)
├── ansible/                 # Platform services via Ansible
│   ├── site.yml             # Main playbook
│   ├── playbooks/           # Individual playbooks
│   └── roles/             # Ansible roles (alb_controller, argocd, external-secrets, monitoring)
└── .github/workflows/       # CI/CD automation (deploy/destroy infrastructure)
```

## Components

| Component | Stack | Description |
|-----------|-------|-------------|
| VPC | Terraform | 2 public subnets, 2 private subnets, IGW, NAT Gateway |
| EKS | Terraform | Kubernetes 1.35 cluster with managed node groups |
| RDS | Terraform | MySQL database for application data |
| Secrets | Terraform | AWS Secrets Manager (DB credentials, JWT secret) |
| ALB Controller | Ansible | AWS Load Balancer Controller for ingress |
| External Secrets | Ansible | Sync AWS Secrets to Kubernetes secrets |
| ArgoCD | Ansible | GitOps continuous deployment |
| Monitoring | Ansible | Prometheus, Grafana, and observability stack |

## Prerequisites

- Terraform >= 1.10.0
- AWS CLI v2
- kubectl
- Helm 3
- Ansible (for platform services deployment)
- Python pip (for Ansible kubernetes.core collection)

## Quick Start

### 1. Bootstrap (One-time)

```bash
cd terraform/bootstrap
terraform init
terraform apply -auto-approve -var-file="terraform.tfvars"
./migrate.sh
```

See [Bootstrap Documentation](terraform/bootstrap/how_to_run.md) for detailed setup.

### 2. Deploy Infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform apply
```

### 3. Deploy Platform Services

```bash
ansible-playbook -i localhost, ansible/site.yml \
  -e "vpc_id=$(terraform output -raw vpc_id)" \
  -e "cluster_name=shopverse-cluster" \
  -e "aws_region=us-east-1"
```

## CI/CD

Main infrastructure is deployed via GitHub Actions:

- **Deploy**: `.github/workflows/main-infrastructure.yml` - provisions and deploys platform services
- **Destroy**: `.github/workflows/destroy-main-infrastructure.yml` - tears down all infrastructure

## Documentation

- [Terraform Documentation](terraform/README.md) - Detailed deployment guide
- [Bootstrap Documentation](terraform/bootstrap/how_to_run.md) - Initial setup instructions
- [Destroy Guide](terraform/how-to-destroy.md) - Clean teardown instructions

## Destroy

```bash
# Delete Kubernetes resources first
helm uninstall shopverse -n shopverse 2>/dev/null || true
kubectl delete pvc --all -n shopverse 2>/dev/null || true
kubectl delete namespace shopverse 2>/dev/null || true

# Then destroy Terraform resources
cd terraform
terraform destroy
```