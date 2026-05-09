---
name: okd-verify
description: Verify cluster health
---

Usage: `/okd-verify <name>`

Invokes the `okd-verify` skill on the named cluster. Runs `scripts/verify.sh --cluster <name>` (using the tools at `bin/<version>/` pinned by `clusters/<name>/version`), shows the verify-report as a table, and auto-invokes `okd-diagnose` if any check fails or any ClusterOperator is Degraded.
