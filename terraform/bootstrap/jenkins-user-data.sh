#!/bin/bash
set -e

# ── Base packages ───────────────────────────────────────────────────────────
apt-get update
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  unzip \
  jq \
  git \
  python3-pip \
  python3-venv

# ── Jenkins ─────────────────────────────────────────────────────────────────
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update
apt-get install -y jenkins

# ── Terraform ───────────────────────────────────────────────────────────────
TERRAFORM_VERSION="1.10.0"
curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
unzip -o /tmp/terraform.zip -d /usr/local/bin/
rm -f /tmp/terraform.zip

# ── Ansible ─────────────────────────────────────────────────────────────────
pip3 install --break-system-packages ansible ansible-core || pip3 install ansible ansible-core

# ── kubectl ───────────────────────────────────────────────────────────────────
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

# ── Helm ──────────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── AWS CLI v2 ────────────────────────────────────────────────────────────────
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -o /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# ── SSM Agent (ensure latest) ─────────────────────────────────────────────────
snap install amazon-ssm-agent --classic 2>/dev/null || true
systemctl enable amazon-ssm-agent || true
systemctl start amazon-ssm-agent || true

# ── CloudWatch Agent ──────────────────────────────────────────────────────────
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb
dpkg -i /tmp/amazoncloudwatch-agent.deb 2>/dev/null || true

# ── Jenkins service ───────────────────────────────────────────────────────────
systemctl enable jenkins
systemctl start jenkins

echo "=== Jenkins bootstrap complete ==="
echo "Terraform: $(terraform version -json | jq -r '.terraform_version')"
echo "Kubectl:   $(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')"
echo "Helm:      $(helm version --short)"
echo "AWS CLI:   $(aws --version)"
