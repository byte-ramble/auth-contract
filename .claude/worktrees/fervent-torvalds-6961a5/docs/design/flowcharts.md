# BSC Topic 权限合约流程图（v1.0）

关联文档：`../requirements/product-requirements.md`、`./architecture.md`、`../operations/runbook.md`

## 1. 系统生命周期总流程
```mermaid
flowchart TD
    A["部署 Deploy.s.sol"] --> B["初始化 initialize(owner, oracle, maxOracleDelay)"]
    B --> C["后置配置<br/>setExecutors / setPaymentToken / setStableToken / setGlobalTrial / setTopicTrial / setTopicPaymentAllowlist / setTopicPaymentToken / setRamblePair(可选)"]
    C --> D["创建 Topic<br/>createTopic/createTopicByKey"]
    D --> E["用户访问与充值循环"]
    E --> F{"版本升级?"}
    F -- "否" --> E
    F -- "是" --> G["Upgrade.s.sol 或 UpgradeAndMigrate.s.sol"]
    G --> H["升级后校验<br/>topic/expiry/whitelist/config"]
    H --> E
```

## 2. 鉴权 `hasAccess` 详细流程
```mermaid
flowchart TD
    A["输入 topicId + user"] --> B{"topic.exists?"}
    B -- "否" --> R0["返回 false"]
    B -- "是" --> C{"whitelist[topicId][user]?"}
    C -- "是" --> R1["返回 true"]
    C -- "否" --> D{"trial still active?"}
    D -- "是" --> R2["返回 true"]
    D -- "否" --> E{"monthlyPriceWad == 0?"}
    E -- "是" --> R3["返回 true"]
    E -- "否" --> F{"expiry >= block.timestamp?"}
    F -- "是" --> R4["返回 true"]
    F -- "否" --> R5["返回 false"]
```

## 3. 充值 `topup` 主流程
```mermaid
flowchart TD
    A["topup(topicId,payToken,amountIn,beneficiary)"] --> B{"amountIn > 0 && beneficiary != 0?"}
    B -- "否" --> X0["revert"]
    B -- "是" --> C{"topic exists?"}
    C -- "否" --> X1["revert TopicNotFound"]
    C -- "是" --> D{"beneficiary 白名单?"}
    D -- "是" --> X2["revert WhitelistedUserNoPaymentRequired"]
    D -- "否" --> E{"trial still active?"}
    E -- "是" --> X3["revert TrialPeriodNoPaymentRequired"]
    E -- "否" --> F{"monthlyPriceWad == 0?"}
    F -- "是" --> X4["revert FreeTopicNoPaymentRequired"]
    F -- "否" --> F1{"allowlist 启用且 payToken 被允许?"}
    F1 -- "否" --> X4A["revert PayTokenNotAllowedForTopic"]
    F1 -- "是" --> G{"payToken 类型"}

    G -- "BNB (address(0))" --> H["校验 msg.value == amountIn<br/>raw/effective = quoteBnbValueWad"]
    G -- "RAMBLE" --> I{"chainId == 56?"}
    I -- "否" --> X5A["revert RambleOnlySupportedOnBsc"]
    I -- "是" --> I1["safeTransferFrom(msg.sender -> this)<br/>effective = swapRambleToBnb(amountIn)"]
    G -- "已启用 payment token" --> J["safeTransferFrom 后按实际到账计价<br/>oracle token -> quoteConfiguredTokenValueWad<br/>stable wrapper -> 1:1 USD"]
    G -- "其他" --> X5["revert UnsupportedPayToken"]

    H --> K{"effective >= monthlyPriceWad?"}
    I1 --> K
    J --> K
    K -- "否" --> X6["revert MinimumPaymentNotMet"]
    K -- "是" --> L["secondsAdded = effective * 30days / monthlyPriceWad"]
    L --> M["newExpiry = max(oldExpiry, now) + secondsAdded"]
    M --> N["写入 expiry 并发 Topup 事件"]
```

## 4. RAMBLE 真实兑换路径（交易内结算）
```mermaid
flowchart TD
    A{"chainId == 56?"} -->|否| X0["revert RambleOnlySupportedOnBsc"]
    A -->|是| B["读取 rambleWbnbPair"]
    B --> C{"pair 地址有效且有代码?"}
    C -- "否" --> X1["revert RamblePairNotConfigured"]
    C -- "是" --> D["读取 token0/token1/reserves"]
    D --> E{"pair 包含 RAMBLE 且储备>0?"}
    E -- "否" --> X2["revert PairTokenMismatch/PairLiquidityTooLow"]
    E -- "是" --> F["RAMBLE 转入 pair"]
    F --> G["计算 amountInActual 与 expectedWbnbOut"]
    G --> H{"expectedWbnbOut > 0?"}
    H -- "否" --> X3["revert PairLiquidityTooLow"]
    H -- "是" --> I["调用 pair.swap 拿到 WBNB"]
    I --> J{"wrappedReceived > 0?"}
    J -- "否" --> X4["revert PairLiquidityTooLow"]
    J -- "是" --> K["调用 WBNB.withdraw(wrappedReceived)"]
    K --> L{"withdraw 成功?"}
    L -- "否" --> X5["revert WrappedNativeWithdrawFailed"]
    L -- "是" --> M["rawValueWad = quoteBnbValueWad(wrappedReceived)"]
    M --> N["effectiveValueWad = rawValueWad * 10000 / discountBps"]
    N --> O{"effective >= monthlyPriceWad?"}
    O -- "否" --> X6["revert MinimumPaymentNotMet(整笔回滚)"]
    O -- "是" --> P["进入 expiry 增量结算"]
```

## 5. 升级与迁移流程（旧版推荐）
```mermaid
flowchart TD
    A["执行 UpgradeAndMigrate.s.sol"] --> B["部署新 implementation"]
    B --> C["proxy.upgradeTo(newImpl)"]
    C --> D["读取 getLegacyStableTokens()"]
    D --> E{"legacyUsdc 有效?"}
    E -- "是" --> E1["setStableToken(legacyUsdc,true)"]
    E -- "否" --> F
    E1 --> F{"legacyUsdt 有效且 != legacyUsdc?"}
    F -- "是" --> F1["setStableToken(legacyUsdt,true)"]
    F -- "否" --> G
    F1 --> G["执行升级后核验<br/>hasAccess/topup/quote/state"]
```

## 6. 人工订阅期纠偏流程
```mermaid
flowchart TD
    A["客服/运维确认需要补偿或迁移纠偏"] --> B{"需要精确覆盖 expiry?"}
    B -- "是" --> C["owner 调用 setExpiry(topicId,user,newExpiry)"]
    B -- "否" --> D["owner 调用 extendExpiry(topicId,user,durationSeconds)"]
    C --> E["发出 ExpiryUpdated 事件"]
    D --> E
    E --> F["链下后台同步新 expiry 并复核 hasAccess"]
```

## 7. 运维应急流程（暂停与恢复）
```mermaid
flowchart TD
    A["监控发现异常<br/>oracle stale / pair 异常 / 对账异常"] --> B["owner 执行 pause()"]
    B --> C["充值路径冻结（topup 拒绝）"]
    C --> D["排障：配置修复/流动性恢复/升级补丁"]
    D --> E["回归验证：hasAccess/topup/quote/privilegedCall"]
    E --> F{"验证通过?"}
    F -- "否" --> D
    F -- "是" --> G["owner 执行 unpause()"]
    G --> H["恢复业务并持续监控"]
```

## 8. 使用说明
- 以上流程图与 `../operations/runbook.md` 的 runbook 一一对应。
- 如果图与实现不一致，以合约行为与测试结果为准，并回改本文档。
