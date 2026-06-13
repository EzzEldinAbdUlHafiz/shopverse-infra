# Infrastructure Destruction Guide (Updated)

This guide provides the exact steps to wipe the Shopverse infrastructure clean from AWS to avoid incurring costs. Because the state bucket uses **S3 Versioning**, a standard delete is not sufficient.

## ⚠️ Warning
Executing these steps will **permanently delete** all data, including the RDS database, EKS cluster, and all Terraform state history.

---

## Step 1: Disable Destruction Protection
The bootstrap bucket is protected by a `prevent_destroy = true` lifecycle rule. To wipe the bucket you must temporarily remove this protection.

1. Open `terraform/bootstrap/main.tf`.
2. Change `prevent_destroy = true` to `prevent_destroy = false` in the `aws_s3_bucket` resource.
3. Save the file.
4. (Recommended) After the full wipe, flip it back to `true` to lock the bucket down again.

## Step 2: Destroy Main Infrastructure
Remove the primary resources managed by the remote state.

The most efficient way to do this is using the helper scripts:

```bash
# Destroy main infrastructure first
./ansible/ansible-destroy.sh 2>/dev/null || true   # optional, if present
cd terraform && terraform destroy -auto-approve && cd ..

# Then destroy the bootstrap (S3 bucket, ECR, etc.)
./terraform/bootstrap-run.sh destroy
```
*`bootstrap-run.sh` reads the S3 state, destroys the bootstrap resources, and leaves the state file in place — you still need Step 3 to fully wipe the bucket.*

## Step 3: Deep Clean S3 Backend (Crucial)
Because S3 Versioning is enabled, the bucket will still contain "hidden" versions and delete markers, preventing the bucket from being fully deleted. Use this sequence to wipe it:

```bash
# Set bucket name (matches the naming in bootstrap/main.tf)
BUCKET="shopverse-tfstate-<your-account-id>"

# 1. List all versions and delete markers and format for the AWS CLI
aws s3api list-object-versions --bucket $BUCKET --output json > all_versions.json

# 2. Create the delete batch file using jq
jq '{Objects: ([.Versions // [] | .[] | {Key: .Key, VersionId: .VersionId}] + [.DeleteMarkers // [] | .[] | {Key: .Key, VersionId: .VersionId}])}' all_versions.json > delete_batch.json

# 3. Execute the mass deletion
aws s3api delete-objects --bucket $BUCKET --delete file://delete_batch.json

# 4. Finally, remove the empty bucket
aws s3 rb s3://$BUCKET

# Cleanup local temp files
rm all_versions.json delete_batch.json
```

## Verification
To confirm everything is gone:
- **AWS Console $\rightarrow$ EC2 $\rightarrow$ Instances**: Should be empty.
- **AWS Console $\rightarrow$ RDS $\rightarrow$ Databases**: Should be empty.
- **AWS Console $\rightarrow$ EKS $\rightarrow$ Clusters**: Should be empty.
- **AWS Console $\rightarrow$ S3 $\rightarrow$ Buckets**: `shopverse-tfstate-<your-account-id>` should no longer exist.
