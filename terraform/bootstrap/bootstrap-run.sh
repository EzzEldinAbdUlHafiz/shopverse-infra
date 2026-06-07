#!/usr/bin/env bash

# bootstrap-run.sh
# ----------------------------------------------------------------------------
# Routine operations for the Shopverse bootstrap (S3 state bucket, ECR).
#
# First-time setup uses a two-step process:
#   1. backend.tf has 'backend "local" {}' so the S3 bucket can be created
#      without a chicken-and-egg dependency on the very bucket that holds
#      the state.
#   2. Once the bucket exists, run ./migrate.sh — it rewrites backend.tf to
#      point at S3 and runs 'terraform init -migrate-state' to move the
#      local state into the bucket.
#
# This script handles everything AFTER that two-step process: re-apply,
# destroy, wipe, and force-unlock.
#
# Usage:
#   ./bootstrap-run.sh apply     (default) - plan + apply against the S3 backend
#   ./bootstrap-run.sh destroy              - destroy bootstrap resources
#   ./bootstrap-run.sh wipe                  - launder S3 versioning and fully wipe
#   ./bootstrap-run.sh unlock               - force-unlock after a crashed run
#   ./bootstrap-run.sh output <name>        - read a single output value
# ----------------------------------------------------------------------------

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

command -v terraform &>/dev/null || error "terraform not found in PATH"
command -v aws       &>/dev/null || error "aws CLI not found in PATH"
command -v jq        &>/dev/null || error "jq not found — install it to use the 'wipe' command."

# Refuse to run routine ops if state is still local — caller should run
# ./migrate.sh first.
# We use grep -v to ignore comments so we don't trip on the example text in backend.tf.
if [[ "${1:-apply}" != "wipe" ]] && grep -v '^[[:space:]]*#' backend.tf 2>/dev/null | grep -q 'backend "local"' ; then
  error "backend.tf still points to 'backend \"local\" {}'. Run ./migrate.sh first."
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
run_apply() {
  info "Initialising against S3 backend..."
  terraform init -input=false

  info "Applying..."
  terraform apply -auto-approve

  info ""
  info "Bootstrap outputs:"
  terraform output
}

run_destroy() {
  warn "This will DESTROY the S3 state bucket and all ECR repos."
  warn "If the state bucket is versioned, it will refuse to be fully deleted"
  warn "until all versions are purged — use './bootstrap-run.sh wipe' for a full clean."
  read -rp "Type 'destroy' to confirm: " CONFIRM
  [[ "${CONFIRM}" == "destroy" ]] || { info "Aborted."; exit 0; }

  info "Destroying..."
  terraform destroy -auto-approve
  info "Done. The state file may still exist in S3."
}

run_wipe() {
  warn "FULL WIPE: This will destroy all resources AND purge the S3 state bucket history."
  read -rp "Type 'wipe' to confirm: " CONFIRM
  [[ "${CONFIRM}" == "wipe" ]] || { info "Aborted."; exit 0; }

  # 1. Destroy managed resources
  info "Step 1: Running terraform destroy..."
  terraform destroy -auto-approve || warn "Terraform destroy failed or resources already gone."

  # 2. Determine bucket name
  # Try to get from terraform output first, fallback to parsing tfvars
  BUCKET=$(terraform output -raw tfstate_bucket_name 2>/dev/null || \
           grep "project_name" terraform.tfvars | cut -d'=' -f2 | tr -d ' "'' | sed 's/$/-tfstate/')

  [[ -z "${BUCKET}" ]] && error "Could not determine S3 bucket name."
  info "Target bucket for deep-clean: $BUCKET"

  # 3. S3 Deep Clean (Purge versions)
  info "Step 2: Purging all S3 object versions and delete markers..."
  aws s3api list-object-versions --bucket "$BUCKET" --output json > all_versions.json

  # Check if bucket is empty
  if [[ $(jq '.Versions | length' all_versions.json) -eq 0 ]] && [[ $(jq '.DeleteMarkers | length' all_versions.json) -eq 0 ]]; then
    info "Bucket is already empty."
  else
    jq '{Objects: ([.Versions // [] | .[] | {Key: .Key, VersionId: .VersionId}] + [.DeleteMarkers // [] | .[] | {Key: .Key, VersionId: .VersionId}])}' all_versions.json > delete_batch.json
    aws s3api delete-objects --bucket "$BUCKET" --delete file://delete_batch.json
    info "Versions purged."
  fi

  # 4. Remove Bucket
  info "Step 3: Removing bucket..."
  aws s3 rb "s3://$BUCKET" || warn "Bucket removal failed (may have already been deleted)."

  # Cleanup
  rm -f all_versions.json delete_batch.json
  info "Full wipe complete."
}

run_unlock() {
  # S3 native locking: the lock ID is shown in the error output of the
  # failed terraform command. There is no on-disk lock file to read.
  read -rp "Enter the lock ID (from the Terraform error output): " LOCK_ID
  [[ -n "${LOCK_ID:-}" ]] || error "Lock ID is required."

  terraform force-unlock "${LOCK_ID}" || warn "Unlock failed (lock may have already expired)."
  info "Unlock attempted."
}

run_output() {
  local name="${1:-}"
  [[ -n "${name}" ]] || error "Usage: $0 output <name>"
  terraform output -raw "${name}"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-apply}" in
  apply)
    run_apply
    ;;
  destroy)
    run_destroy
    ;;
  wipe)
    run_wipe
    ;;
  unlock)
    run_unlock
    ;;
  output)
    shift
    run_output "$@"
    ;;
  *)
    echo "Usage: $0 [apply|destroy|wipe|unlock|output <name>]"
    exit 1
    ;;
esac
