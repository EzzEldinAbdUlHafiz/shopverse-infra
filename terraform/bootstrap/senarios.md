Here is the **final updated runbook** with the `import` block guidance integrated into the scenarios where it belongs.

---

## Pre-Flight Check

Run this on **your_local_machine** to determine which scenario you are in **before** triggering the workflow.

```bash
#!/bin/bash
BUCKET="shopverse-tfstate-your-account-id"
echo "=== IAM Roles ==="
aws iam get-role --role-name shopverse-jenkins-role --region us-east-1 2>/dev/null && echo "❌ shopverse-jenkins-role EXISTS" || echo "✅ shopverse-jenkins-role GONE"
aws iam get-role --role-name shopverse-github-app-role --region us-east-1 2>/dev/null && echo "❌ shopverse-github-app-role EXISTS" || echo "✅ shopverse-github-app-role GONE"

echo "=== IAM Policies ==="
aws iam get-policy --policy-arn arn:aws:iam::587628267564:policy/shopverse-jenkins-boundary --region us-east-1 2>/dev/null && echo "❌ shopverse-jenkins-boundary EXISTS" || echo "✅ shopverse-jenkins-boundary GONE"

echo "=== S3 Bucket ==="
aws s3api head-bucket --bucket "$BUCKET" --region us-east-1 2>/dev/null && echo "⚠️  $BUCKET bucket EXISTS" || echo "✅ $BUCKET bucket GONE"

echo "=== State File in S3 ==="
aws s3api head-object --bucket "$BUCKET" --key bootstrap/terraform.tfstate --region us-east-1 2>/dev/null && echo "⚠️  terraform.tfstate EXISTS in S3" || echo "✅ terraform.tfstate NOT in S3"
```

Use the results to identify your scenario below.

---

## Scenario 1: Absolute Zero

**Symptoms:** All checks above return `GONE` or `NOT in S3`. Nothing exists in AWS.

**What Happens When You Trigger the Workflow**

| Step | Result |
|------|--------|
| `Detect run mode` | `head-bucket` fails → `mode=local` |
| `Init (local)` | ✅ Terraform initializes with local backend |
| `Apply` | ✅ Creates S3 bucket, ECR repos, VPC, Jenkins EC2, IAM roles |
| `Backup local state` | ✅ Uploads `terraform.tfstate` as GitHub artifact |
| `Write backend config` | ✅ Generates `backend.tf` with S3 backend |
| `Migrate state to S3` | ✅ Copies state to `s3://shopverse-tfstate-<your-account-id>/bootstrap/terraform.tfstate` |
| **Final State** | 🟢 **Bootstrap complete. State lives in S3.** |

**Next Run:** Will detect `mode=remote`, run `init -reconfigure`, plan/apply, no changes.

**Resolution Required:** None. Just trigger the workflow.

**Import Block Note:** Not needed. Terraform creates everything fresh.

---

## Scenario 2: IAM Orphans (Roles/Policies Exist, Nothing Else)

**Symptoms:** 
- `shopverse-jenkins-role` or `shopverse-github-app-role` or `shopverse-jenkins-boundary` returns `EXISTS`
- S3 bucket is `GONE`
- VPC and Jenkins are `GONE`

**What Happens When You Trigger the Workflow**

| Step | Result |
|------|--------|
| `Detect run mode` | `head-bucket` fails → `mode=local` |
| `Init (local)` | ✅ Terraform initializes |
| `Apply` | 💥 **FAILS** on `aws_iam_role.jenkins` |
| Error | `EntityAlreadyExists: Role with name shopverse-jenkins-role already exists.` |
| **Final State** | 🔴 **Workflow dead. Resources partially created or zero progress.** |

**Why It Breaks:** The workflow only checks for the S3 bucket. It does not check for IAM roles. Terraform tries to create roles that already exist in AWS.

**Resolution on your_local_machine**

Run these commands in exact order (IAM has strict dependencies):

```bash
#!/bin/bash
set -e

# 1. Remove Jenkins instance profile from role
aws iam remove-role-from-instance-profile \
  --instance-profile-name shopverse-jenkins-profile \
  --role-name shopverse-jenkins-role \
  --region us-east-1 2>/dev/null || true

# 2. Delete Jenkins instance profile
aws iam delete-instance-profile \
  --instance-profile-name shopverse-jenkins-profile \
  --region us-east-1 2>/dev/null || true

# 3. Detach managed policy from Jenkins role
aws iam detach-role-policy \
  --role-name shopverse-jenkins-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --region us-east-1 2>/dev/null || true

# 4. Delete Jenkins inline custom policy
aws iam delete-role-policy \
  --role-name shopverse-jenkins-role \
  --policy-name shopverse-jenkins-custom-policy \
  --region us-east-1 2>/dev/null || true

# 5. Remove permissions boundary from Jenkins role (required before deleting role)
aws iam delete-role-permissions-boundary \
  --role-name shopverse-jenkins-role \
  --region us-east-1 2>/dev/null || true

# 6. Delete Jenkins role
aws iam delete-role \
  --role-name shopverse-jenkins-role \
  --region us-east-1 2>/dev/null || true

# 7. Delete Jenkins boundary policy (now unattached)
aws iam delete-policy \
  --policy-arn arn:aws:iam::587628267564:policy/shopverse-jenkins-boundary \
  --region us-east-1 2>/dev/null || true

# 8. Delete GitHub app inline policy
aws iam delete-role-policy \
  --role-name shopverse-github-app-role \
  --policy-name shopverse-github-app-perms \
  --region us-east-1 2>/dev/null || true

# 9. Delete GitHub app role
aws iam delete-role \
  --role-name shopverse-github-app-role \
  --region us-east-1 2>/dev/null || true

echo "=== Verification ==="
aws iam get-role --role-name shopverse-jenkins-role --region us-east-1 2>/dev/null && echo "❌ Still exists" || echo "✅ shopverse-jenkins-role deleted"
aws iam get-role --role-name shopverse-github-app-role --region us-east-1 2>/dev/null && echo "❌ Still exists" || echo "✅ shopverse-github-app-role deleted"
aws iam get-policy --policy-arn arn:aws:iam::587628267564:policy/shopverse-jenkins-boundary --region us-east-1 2>/dev/null && echo "❌ Still exists" || echo "✅ shopverse-jenkins-boundary deleted"
```

**After Resolution:** You are now in **Scenario 1**. Trigger the workflow.

**Import Block Note:** Not needed. You destroyed the orphans. Terraform creates everything fresh.

---

## Scenario 3: Infrastructure Exists, State File Missing

**Symptoms:**
- S3 bucket `shopverse-tfstate-<your-account-id>` returns `EXISTS`
- `terraform.tfstate` in S3 returns `NOT in S3`
- Other resources may or may not exist (ECR, VPC, Jenkins)

**What Happens When You Trigger the Workflow**

| Step | Result |
|------|--------|
| `head-bucket` | ✅ Succeeds |
| `head-object` | ❌ Fails (no `terraform.tfstate` key) |
| **Mode** | `orphan` |
| `Orphan bucket guard` | Prints error message and `exit 1` |
| **Final State** | 🟡 **Workflow blocked safely. No resources created or destroyed.** |

**Why This Is Good:** The workflow detects that the bucket exists but Terraform has no memory of what is inside it. If it proceeded, it would try to recreate everything and hit `AlreadyExists`.

**Resolution: Two Paths**

### Path A: Nuclear Reset (Recommended for Graduation Projects)

Destroy everything and return to **Scenario 1**.

Run on **your_local_machine**:

```bash
#!/bin/bash
set -e

BUCKET="shopverse-tfstate-your-account-id"
REGION="us-east-1"

echo "=== 1. Delete all S3 object versions ==="
aws s3api delete-objects \
  --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json --region "$REGION" 2>/dev/null)" \
  --region "$REGION" 2>/dev/null || true

echo "=== 2. Delete all S3 delete markers ==="
aws s3api delete-objects \
  --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json --region "$REGION" 2>/dev/null)" \
  --region "$REGION" 2>/dev/null || true

echo "=== 3. Delete S3 bucket ==="
aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null || true

echo "=== 4. Delete IAM orphans (same as Scenario 2) ==="
aws iam remove-role-from-instance-profile --instance-profile-name shopverse-jenkins-profile --role-name shopverse-jenkins-role --region "$REGION" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name shopverse-jenkins-profile --region "$REGION" 2>/dev/null || true
aws iam detach-role-policy --role-name shopverse-jenkins-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore --region "$REGION" 2>/dev/null || true
aws iam delete-role-policy --role-name shopverse-jenkins-role --policy-name shopverse-jenkins-custom-policy --region "$REGION" 2>/dev/null || true
aws iam delete-role-permissions-boundary --role-name shopverse-jenkins-role --region "$REGION" 2>/dev/null || true
aws iam delete-role --role-name shopverse-jenkins-role --region "$REGION" 2>/dev/null || true
aws iam delete-policy --policy-arn arn:aws:iam::587628267564:policy/shopverse-jenkins-boundary --region "$REGION" 2>/dev/null || true
aws iam delete-role-policy --role-name shopverse-github-app-role --policy-name shopverse-github-app-perms --region "$REGION" 2>/dev/null || true
aws iam delete-role --role-name shopverse-github-app-role --region "$REGION" 2>/dev/null || true

echo "=== 5. Delete VPC and dependencies ==="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=shopverse-vpc" --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null)
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  # Terminate Jenkins
  for INST in $(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=shopverse-jenkins" --query 'Reservations[*].Instances[*].InstanceId' --output text --region "$REGION" 2>/dev/null); do
    aws ec2 terminate-instances --instance-ids "$INST" --region "$REGION" || true
    aws ec2 wait instance-terminated --instance-ids "$INST" --region "$REGION" || true
  done
  
  # Delete IGW
  IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null)
  [ "$IGW_ID" != "None" ] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || true
  [ "$IGW_ID" != "None" ] && aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" 2>/dev/null || true
  
  # Delete subnets
  for SUBNET in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --region "$REGION" 2>/dev/null); do
    aws ec2 delete-subnet --subnet-id "$SUBNET" --region "$REGION" 2>/dev/null || true
  done
  
  # Delete route tables (except main)
  for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text --region "$REGION" 2>/dev/null); do
    aws ec2 delete-route-table --route-table-id "$RT" --region "$REGION" 2>/dev/null || true
  done
  
  # Delete security groups (except default)
  for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region "$REGION" 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>/dev/null || true
  done
  
  # Delete VPC
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || true
fi

echo "=== 6. Delete ECR repositories ==="
aws ecr delete-repository --repository-name shopverse-frontend --force --region "$REGION" 2>/dev/null || true
aws ecr delete-repository --repository-name shopverse-backend --force --region "$REGION" 2>/dev/null || true

echo "=== DONE. You are now in Scenario 1. ==="
```

**After Resolution:** Trigger the workflow. It will run in `local` mode and create everything.

**Import Block Note:** Not needed. You destroyed everything. Terraform creates fresh.

---

### Path B: Reconcile with Import Blocks (For Production — Keep Existing Resources)

If you have data in the S3 bucket or ECR repos you cannot delete, you must adopt the existing resources into Terraform state.

**The `import` block is a temporary surgical tool.** It tells Terraform: "This resource already exists in AWS — adopt it into state instead of creating it."

#### Step 1: Add Temporary Import Blocks

On **your_local_machine**, edit `terraform/bootstrap/main.tf` and add these at the top:

```hcl
# ──────────────────────────────────────────────
# TEMPORARY: Import existing resources into state
# DELETE THESE BLOCKS AFTER SUCCESSFUL APPLY
# ──────────────────────────────────────────────
import {
  to = aws_s3_bucket.tfstate
  id = "shopverse-tfstate-your-account-id"
}

# Add more imports as needed based on what exists:
# import {
#   to = aws_vpc.main
#   id = "vpc-xxxxxxxxxxxxxxxxx"
# }
# import {
#   to = aws_iam_role.jenkins
#   id = "shopverse-jenkins-role"
# }
```

#### Step 2: Find Resource IDs

```bash
# VPC
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=shopverse-vpc" --query 'Vpcs[0].VpcId' --output text --region us-east-1

# ECR repos
aws ecr describe-repositories --repository-names shopverse-frontend shopverse-backend --region us-east-1

# IAM roles
aws iam get-role --role-name shopverse-jenkins-role --region us-east-1
aws iam get-role --role-name shopverse-github-app-role --region us-east-1
```

#### Step 3: Initialize and Plan

```bash
cd terraform/bootstrap
terraform init
terraform plan -var-file="github-ci.tfvars" -generate-config-out=generated.tf
```

Terraform will show you which resources it plans to **import** (adopt) vs. **create** (new).

#### Step 4: Apply to Adopt

```bash
terraform apply -var-file="github-ci.tfvars"
```

Type `yes`. Terraform imports the resources into state and creates any missing ones.

#### Step 5: CRITICAL — Remove Import Blocks Before Committing

```bash
# Delete the import blocks from main.tf
sed -i '/^import {/,/^}/d' main.tf  # Or manually edit and delete them
```

**Never commit `import` blocks to your main branch.** They are one-time use. If the resource is destroyed later and the `import` block is still in the code, Terraform will fail with `Cannot import non-existent remote object`.

#### Step 6: Migrate to S3 Backend

```bash
cat > backend.tf <<'EOF'
terraform {
  backend "s3" {
    bucket       = "shopverse-tfstate-your-account-id"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
EOF
terraform init -migrate-state
```

Type `yes`.

#### Step 7: Clean Up and Push

```bash
rm -f backend.tf generated.tf
rm -f terraform.tfstate terraform.tfstate.backup
rm -rf .terraform

# Verify import blocks are gone
grep -n "import {" main.tf && echo "❌ Import blocks still present!" || echo "✅ Clean"

git add .
git commit -m "reconcile: imported existing resources, state migrated to S3"
git push origin main
```

**After Resolution:** Trigger the workflow. It will run in `remote` mode.

---

## The `import` Block Golden Rule

| Rule | Why |
|------|-----|
| **Import blocks are temporary** | They adopt an existing resource once. After that, they are dead weight. |
| **Never commit import blocks** | If the resource is later destroyed, Terraform will fail on the next plan because the import block references a non-existent resource. |
| **Remove them immediately after successful apply** | The resource is now in state. The block has done its job. |
| **Use `terraform plan` first** | Always preview what Terraform will import vs. create before applying. |
| **Only import what you must keep** | If you can afford to destroy it, use Path A (Nuclear Reset) instead. |

---

## Universal Golden Rules

| Rule | Why |
|------|-----|
| **Never run `aws delete-*` after the first successful bootstrap** | Terraform owns the resources. CLI deletes create orphans. |
| **Always run the Pre-Flight script before triggering** | Saves you from wasting GitHub Actions minutes on known failures. |
| **If the workflow fails, read the exact error before touching AWS** | `AlreadyExists` = Scenario 2. `BucketAlreadyExists` = Scenario 3. |
| **Never commit `backend.tf` or `terraform.tfstate` to Git** | The workflow generates these. Committing them breaks the first-run logic. |
| **Never commit `import` blocks to main** | One-time use only. Will break future runs if the resource is destroyed. |