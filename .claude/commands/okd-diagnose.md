---
name: okd-diagnose
description: Diagnose cluster failure, match playbooks
---

Usage: `/okd-diagnose <name>`

Invokes the `okd-diagnose` skill. Reads `clusters/<name>/status.json`, collects phase-aware diagnostic material (terraform.log / .openshift_install.log / `oc get co` / verify-report.json depending on phase), filters `docs/playbooks/_index.md` by `applies_to_phase`, runs signal matching, and outputs structured suggestions (症狀 / 原因 / 建議動作 a/b/c). On no match, summarizes via LLM and appends a deduped fingerprint to `docs/playbooks/_unknown.md`. Never auto-executes any fix.
