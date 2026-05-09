---
name: okd-build
description: Build one or more OKD 4.18 clusters on AWS
---

Usage: `/okd-build <name1> [name2 ...] [--version X]`

Invokes the `okd-build` skill with the provided cluster names. The skill parses arguments including `--version` (default `4.18.0-okd-scos.10`), runs a single shared preflight, then dispatches one parallel sub-agent per cluster covering the full lifecycle (terraform → ccoctl → render → patch → install → verify). Failures auto-trigger `okd-diagnose`.
