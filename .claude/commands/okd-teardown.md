---
name: okd-teardown
description: Tear down OKD cluster(s) and clean AWS resources
---

Usage: `/okd-teardown <name1> [name2 ...] [--purge]`

Invokes the `okd-teardown` skill. Per cluster (parallel via sub-agents), runs `scripts/teardown.sh --cluster <name>`: phase-aware destroy of installer resources, terraform-managed VPC, and ccoctl-created S3 / IAM / OIDC. With `--purge`, also removes the entire `clusters/<name>/` directory. On `terraform destroy` failure (e.g. `DependencyViolation`), auto-invokes `okd-diagnose`.
