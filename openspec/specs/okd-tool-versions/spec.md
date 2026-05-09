# okd-tool-versions Specification

## Purpose
TBD - created by archiving change okd-ai-agent. Update Purpose after archive.
## Requirements
### Requirement: 多版本工具目錄結構
系統 SHALL 在 `bin/<version>/` 下分別放置每個 OKD 版本的 `openshift-install`、`ccoctl`、`oc` 三個執行檔。

#### Scenario: 版本目錄佈局
- **WHEN** user 想同時持有 4.18 與 4.19 工具
- **THEN** 系統存在 `bin/4.18.0-okd-scos.10/{openshift-install,ccoctl,oc}` 與 `bin/4.19.0-okd-scos.5/{openshift-install,ccoctl,oc}`
- **AND** 兩版本互不覆蓋

### Requirement: 集群版本鎖定
系統 SHALL 在每集群目錄寫入 `clusters/<name>/version` 檔，記錄該集群建立時所用的 OKD 版本。後續對該集群的所有腳本操作 MUST 依此檔挑工具。

#### Scenario: 鎖定版本
- **WHEN** user 執行 `/okd-build dev01 --version 4.18.0-okd-scos.10`
- **THEN** 系統在建立集群時把 `4.18.0-okd-scos.10` 寫入 `clusters/dev01/version`

#### Scenario: 後續操作沿用鎖定版本
- **WHEN** user 對 dev01 執行 `/okd-verify dev01` 或 `/okd-teardown dev01`
- **THEN** 系統讀 `clusters/dev01/version` 拿到 `4.18.0-okd-scos.10`
- **AND** 使用 `bin/4.18.0-okd-scos.10/oc` 與 `bin/4.18.0-okd-scos.10/openshift-install`，不論當前環境 PATH 設定

### Requirement: 版本不一致防呆
系統 SHALL 在工具版本與 `clusters/<name>/version` 不一致時拒絕操作。

#### Scenario: 工具版本與集群版本不符
- **WHEN** `clusters/dev01/version` 為 `4.18.0-okd-scos.10`，但 `bin/4.18.0-okd-scos.10/` 不存在或工具被替換
- **THEN** 腳本 MUST 失敗並提示「集群版本工具缺失，請補裝對應版本」
- **AND** 不允許用其他版本工具操作該集群

### Requirement: 版本參數預設
系統 SHALL 為 `/okd-build` 提供預設版本（MVP 為 `4.18.0-okd-scos.10`），user 不指定 `--version` 時採用預設。

#### Scenario: 不指定版本
- **WHEN** user 執行 `/okd-build dev01`（無 `--version`）
- **THEN** 系統使用預設版本 `4.18.0-okd-scos.10`
- **AND** `clusters/dev01/version` 寫入該預設值

### Requirement: 不依賴 PATH
系統 SHALL 確保所有腳本透過絕對路徑（`bin/<version>/<tool>`）呼叫工具，不使用 `which` 或依賴使用者 shell PATH。

#### Scenario: PATH 中有舊版本不影響
- **WHEN** user 系統 PATH 中存在舊版 `oc` 或 `openshift-install`
- **THEN** 系統腳本仍使用 `bin/<version>/` 對應工具，不被 PATH 影響

