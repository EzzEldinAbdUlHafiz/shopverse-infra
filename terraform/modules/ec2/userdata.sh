#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────────────────────────
# Update system packages
# ──────────────────────────────────────────────
echo "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# ──────────────────────────────────────────────
# Install AWS CLI v2
# ──────────────────────────────────────────────
echo "Installing AWS CLI..."
apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws
aws --version

# ──────────────────────────────────────────────
# Install kubectl
# ──────────────────────────────────────────────
echo "Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/
kubectl version --client 2>/dev/null || true

# ──────────────────────────────────────────────
# Install Helm
# ──────────────────────────────────────────────
echo "Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version 2>/dev/null || true

# ──────────────────────────────────────────────
# Install Docker
# ──────────────────────────────────────────────
echo "Installing Docker..."
apt-get install -y ca-certificates gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# ──────────────────────────────────────────────
# Install Git
# ──────────────────────────────────────────────
echo "Installing Git..."
apt-get install -y git

# ──────────────────────────────────────────────
# Configure kubeconfig for EKS
# ──────────────────────────────────────────────
echo "Configuring kubeconfig for EKS cluster: ${cluster_name}..."
su - ubuntu -c "aws eks update-kubeconfig --name ${cluster_name} --region ${aws_region}" || true

echo "Jump server setup complete!"
