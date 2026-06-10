# Shopverse Infrastructure Documentation

## Project Overview
Shopverse is a high-availability e-commerce platform utilizing a modern cloud-native architecture. The infrastructure is designed for security, scalability, and automated delivery, employing a "Launch on Demand" strategy to minimize costs and maximize reproducibility. It leverages a layered provisioning approach where foundational identity and connectivity are established before deploying the core compute and data layers.

## Architecture Summary
The architecture follows a tiered approach:
1.  **Bootstrap Layer (Layer 0):** Establishes trust between GitHub and AWS (OIDC), sets up remote state management (S3), creates container registries (ECR), and deploys a Bastion Host for secure access.
2.  **Core Infrastructure Layer (Layer 1):** Extends networking with private subnets, provisions a managed Kubernetes cluster (EKS), and deploys a managed MySQL database (RDS).
3.  **Platform Services Layer (Layer 2):** Uses Ansible to install the operational stack via Helm, including GitOps (ArgoCD) and Monitoring (Prometheus/Grafana).

## Directory Structure
```text
/infra-repo
├── ansible/                    # Configuration Management
│   ├── roles/                  # Modular installation logic
│   │   ├── argocd/             # GitOps delivery setup
│   │   └── monitoring/         # Prometheus & Grafana stack
│   ├── playbooks/              # Specific execution playbooks
│   ├── site.yml                # Main Ansible entry point
│   └── ansible-run.sh          # Orchestration script for execution
├── terraform/                  # Infrastructure as Code
│   ├── bootstrap/              # Layer 0: Initial AWS setup
│   │   ├── main.tf             # OIDC, S3 State, ECR, Bastion
│   │   └── bootstrap-run.sh    # Execution script for bootstrap
│   ├── modules/                # Reusable IaC components
│   │   ├── vpc/                # Networking (Public/Private subnets)
│   │   ├── eks/                # Managed K8s cluster logic
│   │   ├── rds/                # Managed MySQL database
│   │   ├── ecr/                # Container registries
│   │   └── ec2/                # Compute instances (Bastion)
│   ├── main.tf                 # Layer 1: Main infrastructure orchestration
│   └── backend.tf              # Remote state configuration (S3)
└── README.md                   # General project overview
```

## Technology Stack
- **Cloud Provider:** AWS (us-east-1)
- **IaC:** Terraform
- **Config Management:** Ansible
- **Orchestration:** Kubernetes (Amazon EKS)
- **CI/CD:** GitHub Actions $\rightarrow$ ArgoCD (GitOps)
- **Database:** AWS RDS MySQL
- **Containerization:** Docker, Amazon ECR
- **Observability:** Prometheus, Grafana, Loki
- **Security:** AWS IAM (OIDC), AWS Secrets Manager, External Secrets Operator (ESO)

## Dependencies and External Services
- **GitHub:** Source code hosting and CI trigger.
- **AWS:** Hosting provider for all compute, storage, and networking.
- **Helm:** Package manager for Kubernetes applications.
- **S3:** Used for Terraform state locking and storage.

## Execution Flow
The infrastructure is deployed in a strict linear sequence:
1.  **`terraform/bootstrap`**: Executed first to create the S3 bucket for state and the IAM roles for GitHub Actions.
2.  **`terraform/main`**: Executed second, utilizing the S3 backend created in bootstrap to provision the VPC, EKS, and RDS.
3.  **`ansible-run.sh`**: Executed last to configure the EKS cluster by installing the Platform Stack (ArgoCD, Monitoring).

## Data Flow
- **Infrastructure State:** Terraform $\rightarrow$ AWS S3 (Remote Backend).
- **Application Images:** GitHub Actions $\rightarrow$ Amazon ECR $\rightarrow$ EKS.
- **Application Manifests:** Git Repository $\rightarrow$ ArgoCD $\rightarrow$ Kubernetes Cluster.
- **Metrics:** Pods $\rightarrow$ Prometheus $\rightarrow$ Grafana.
- **Database Traffic:** EKS Pods $\rightarrow$ Security Group $\rightarrow$ RDS MySQL.

## Configuration Files
- **`terraform.tfvars`**: Environment-specific variable overrides for the main infrastructure.
- **`terraform/bootstrap/terraform.tfvars`**: Variables for the initial bootstrap phase.
- **`ansible/ansible.cfg`**: Configuration for Ansible behavior and remote connections.
- **`ansible/requirements.yml`**: Definition of required Ansible collections (`kubernetes.core`, `community.crypto`).

## Detailed File-by-File Documentation

### Terraform Bootstrap
| Path | Purpose | Functionality | Interactions |
| :--- | :--- | :--- | :--- |
| `terraform/bootstrap/main.tf` | L0 Provisioning | Sets up OIDC, IAM roles, S3 State bucket, and Bastion host. | Foundational for all other TF components. |
| `terraform/bootstrap/bootstrap-run.sh` | Execution | Wrapper script to automate the bootstrap application. | Triggers `terraform apply`. |

### Terraform Main
| Path | Purpose | Functionality | Interactions |
| :--- | :--- | :--- | :--- |
| `terraform/main.tf` | L1 Provisioning | Orchestrates the deployment of VPC, EKS, and RDS using modules. | Depends on Bootstrap L0. |
| `terraform/backend.tf` | State Management | Configures Terraform to use the S3 bucket created in bootstrap. | Interacts with S3. |
| `terraform/modules/vpc/main.tf` | Networking | Creates public and private subnets across multiple AZs. | Used by EKS and RDS modules. |
| `terraform/modules/eks/main.tf` | K8s Cluster | Provisions the EKS cluster and managed node groups. | Uses VPC module; grants access to Bastion. |
| `terraform/modules/rds/main.tf` | Database | Provisions the managed MySQL instance. | Uses VPC module; allows EKS node traffic. |

### Ansible
| Path | Purpose | Functionality | Interactions |
| :--- | :--- | :--- | :--- |
| `ansible/site.yml` | Master Playbook | Defines the order of role execution (`argocd` $\rightarrow$ `monitoring`). | Orchestrates all roles. |
| `ansible/ansible-run.sh` | Execution | Handles SSH keys, installs collections, and runs the playbook. | Bridges the gap between TF and K8s. |
| `ansible/roles/argocd/tasks/main.yml`| GitOps Setup | Updates kubeconfig and installs ArgoCD via Helm. | Interacts with AWS EKS API. |
| `ansible/roles/monitoring/tasks/main.yml`| Observability | Installs `kube-prometheus-stack` (Prometheus/Grafana). | Deploys to EKS. |

## Key Workflows
### Infrastructure Provisioning
1. Run `terraform/bootstrap/bootstrap-run.sh`.
2. Run `terraform init` and `terraform apply` in `terraform/`.
3. Run `./ansible/ansible-run.sh` to initialize the platform services (ArgoCD and Monitoring).

### Infrastructure Destruction
1. Run `terraform destroy` in `terraform/`.
2. Run `terraform destroy` in `terraform/bootstrap/`.
3. Manually clean versioned S3 objects as per `terraform/how-to-destroy.md`.

## Critical Logic Paths
- **OIDC Trust:** The connection between GitHub and AWS is the critical path for automated CI/CD. If the OIDC provider is misconfigured, the GitHub Actions pipeline cannot deploy infrastructure.
- **Kubeconfig Bridge:** Ansible's ability to manage the cluster relies on the `aws eks update-kubeconfig` command. This requires the correct IAM identity and AWS region.
- **Network Isolation:** The path from EKS $\rightarrow$ RDS is strictly controlled via Security Groups, ensuring that the database is never exposed to the public internet.

## Integration Points
- **Terraform $\rightarrow$ Ansible:** Terraform provides the `cluster_name` and `region` which Ansible uses to connect to the cluster.
- **Ansible $\rightarrow$ ArgoCD:** Ansible installs ArgoCD, which then integrates with the Git repository to deploy the actual application code.
- **AWS $\rightarrow$ EKS:** The EKS cluster utilizes IAM Roles for Service Accounts (IRSA) to interact with other AWS services (like Secrets Manager) securely.

## Architectural Decisions
- **Layered Bootstrap:** Decoupling the S3 state and OIDC setup from the main infrastructure prevents a "chicken and egg" problem with remote state management.
- **Bastion Host:** A single entry point for SSH and administrative `kubectl` access reduces the attack surface.
- **App-of-Apps Pattern:** Using ArgoCD to manage other ArgoCD applications allows for a hierarchical and scalable deployment structure.
- **Managed Services:** Choosing EKS and RDS over self-managed K8s and MySQL reduces operational overhead and improves reliability.
