# Unused Items Audit

This document lists items identified during the codebase audit as being unused.

## 1. Terraform Variables
- **Location:** `terraform/bootstrap/variables.tf`
- **Item:** `github_repo_gitops`
- **Type:** Terraform Variable
- **Evidence:** `grep -r "var.github_repo_gitops" terraform` returned no results.
- **Risks of Removal:** Low. Removing an unused variable declaration does not affect infrastructure state.
- **Confidence Level:** High

## 2. Ansible Roles
- **Location:** `ansible/roles/logging`
- **Item:** `logging` role
- **Type:** Ansible Role
- **Evidence:** The directory exists in `ansible/roles/`, but it is not referenced in the `roles` list of `ansible/site.yml`.
- **Risks of Removal:** Medium. While not currently active in the main playbook, it may have been intended for future use or used in a separate, non-standard workflow.
- **Confidence Level:** High (regarding its absence from `site.yml`)
