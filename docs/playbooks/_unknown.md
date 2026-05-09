# 未知失敗模式記錄

當 diagnose 無法匹配任何已知 playbook 時，會在此 append 一筆。
日後可挑常見指紋整理為正式 playbook（流程見 `_index.md`）。

## 條目格式

每筆條目用以下結構：

```markdown
## [YYYY-MM-DD HH:MM:SS UTC] <cluster_name> @ <phase>

**Fingerprint**：`<phase>:<log_first_line_hash>`（去重用，避免重複記錄）

**LLM 摘要**：
<Claude 對 log 的一段話摘要>

**值得查的方向**：
- <方向 1>
- <方向 2>
- <方向 3>

**Log 片段**（最後 30 行）：
```
<log content>
```
```

## 條目

<!-- 由 okd-diagnose skill 自動 append；新進條目放最上面 -->
