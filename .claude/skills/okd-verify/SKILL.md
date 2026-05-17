---
name: okd-verify
description: Use to verify health of an existing OKD cluster (after build, ad-hoc, or after suspected issue). Triggered by /okd-verify
---

# okd-verify

對既有 OKD 集群跑健康檢查。此 skill 不建立、不修改 AWS 資源，只用 `oc` 與 `kubeconfig` 讀取狀態。

## 何時使用

- 使用者執行 `/okd-verify <name>`。
- `okd-build` 完成最後一步時自動呼叫一次。
- 使用者懷疑某集群異常（網路、operator degraded、node NotReady）。

## 參數

- 位置參數：一個 cluster 名稱（必要）。
- 版本由 `clusters/<name>/version` 決定，verify 自動挑 `bin/<version>/oc`。

## 入口腳本

```bash
scripts/verify.sh --cluster <name>
```

腳本會：

1. 讀 `clusters/<name>/version`，挑出對應 `bin/<version>/oc`。
2. 用 `clusters/<name>/auth/kubeconfig` 跑檢查項：
   - `oc get nodes`：所有節點 `Ready=True`
   - `oc get co`：所有 ClusterOperator `Available=True / Degraded=False / Progressing=False`
   - 核心 workloads：`openshift-apiserver`、`openshift-authentication`、`openshift-ingress`、`openshift-dns` 全 `Ready`
   - networking：DNS 解析 `console-openshift-console.apps.<name>.<base_domain>` 可解、可 curl 200
   - `worker_eips`：用 tag(`kubernetes.io/cluster/<name>=shared` + `okd-deploy/role=worker-eip`)查所有預配的 worker EIP,確認每一個都已 associated 到 EC2 instance。dangling 就 fail,suggestion 是「re-run scripts/attach-worker-eips.sh」
3. 結果寫進 `clusters/<name>/verify-report.json`，每項標 `ok | warn | fail`，並把 `status.json.verify_summary` 同步更新。
4. 若全綠且當前 phase 為 `verifying` → 推進到 `ready`。

## 行為

1. 跑 `scripts/verify.sh --cluster <name>`。
2. 讀回 `clusters/<name>/verify-report.json`，以 markdown 表格秀給使用者：

   | Check | Status | Detail |
   |---|---|---|
   | nodes_ready | ok | 4/4 Ready |
   | clusteroperators | fail | ingress: Degraded=True |
   | core_workloads | ok | – |
   | networking | warn | DNS 解析正常但 curl 慢 |
   | worker_eips | ok | associated=2/2 |

3. **若任何 ClusterOperator `Degraded=True` 或任何項目 fail** → 自動呼叫 `okd-diagnose` skill，把當前 cluster 與 phase 丟進去。把 diagnose 的建議直接附在 verify 報告之後。
4. 若全 ok → 回應使用者「集群健康」+ kubeconfig 路徑 + console URL。

## 範例

```
/okd-verify dev01
```

預期輸出（健康時）：

```
Cluster: dev01 (phase=ready)
| Check            | Status | Detail              |
| nodes_ready      | ok     | 4/4 Ready           |
| clusteroperators | ok     | 32/32 Available     |
| core_workloads   | ok     | –                   |
| networking       | ok     | console reachable   |
Kubeconfig: clusters/dev01/auth/kubeconfig
Console:    https://console-openshift-console.apps.dev01.<base_domain>
```

不健康時自動接 diagnose 輸出。
