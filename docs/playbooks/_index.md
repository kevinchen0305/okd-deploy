# Playbook Index

Diagnose skill 載入此檔，依 `applies_to_phase` 過濾候選 playbook。
新增 playbook 時務必同步更新此索引。

## 已收錄

| ID | Phase 範圍 | Severity | Auto-fixable |
|---|---|---|---|
| quota-exceeded-vpc | provisioning_vpc | blocker | no |
| quota-exceeded-eip | provisioning_vpc | blocker | no |
| quota-exceeded-ec2 | installing | blocker | no |
| sts-expired | * | blocker | partial (re-run sts-creds.sh) |
| sts-mfa-failed | getting_creds | blocker | no |
| ami-not-found | rendering_config | blocker | no |
| bootstrap-stuck | installing | blocker | no |
| ingress-degraded | verifying | warning | no |
| route53-resolution-failed | installing, verifying | blocker | no |
| ccoctl-s3-conflict | setting_up_iam | blocker | no |
| machineset-no-subnet | patching_manifests | blocker | partial |
| teardown-orphaned-resource | tearing_down | warning | no |
| teardown-guardduty-vpc-residue | tearing_down | warning | partial |

## 升格流程

`_unknown.md` 累積到一定量後，挑常見指紋整理為正式 playbook：
1. 取一筆未知條目，確認失敗已被理解
2. 寫 `<id>.md`：frontmatter 指定 `applies_to_phase`、`signals`、`severity`、`auto_fixable`；內文寫症狀 / 原因 / 建議
3. 在本檔表格加一行
4. 從 `_unknown.md` 移除對應指紋的條目
