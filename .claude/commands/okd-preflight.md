---
name: okd-preflight
description: Run preflight checks without building
---

Usage: `/okd-preflight <name1> [name2 ...] [--version X]`

Invokes the `okd-preflight` skill. Runs `scripts/preflight.sh --clusters <list> --version <ver> --region <r>` (default version `4.18.0-okd-scos.10`), parses the JSON result, and presents a pass/fail table covering: AWS quotas (VPC / EIP / NAT / EC2), STS validity, AMI existence, tools at `bin/<version>/`, cluster name conflicts, and account-ID consistency. Read-only — never touches AWS or cluster directories. On `fail`, auto-invokes `okd-diagnose` for matching playbooks.
