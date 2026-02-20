# BSC Topic 权限合约流程图（v1.0）

关联文档：`./01-requirements.md`、`./02-design.md`、`./05-operations.md`

## 1. 系统生命周期总流程
```mermaid
flowchart TD
    A["部署 Deploy.s.sol"] --> B["初始化 initialize(owner, oracle, maxOracleDelay)"]
    B --> C["后置配置<br/>setExecutors / setStableToken / setRamblePair(可选)"]
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
    C -- "否" --> D{"monthlyPriceWad == 0?"}
    D -- "是" --> R2["返回 true"]
    D -- "否" --> E{"expiry >= block.timestamp?"}
    E -- "是" --> R3["返回 true"]
    E -- "否" --> R4["返回 false"]
```

## 3. 充值 `topup` 主流程
```mermaid
flowchart TD
    A["topup(topicId,payToken,amountIn,beneficiary)"] --> B{"amountIn > 0 && beneficiary != 0?"}
    B -- "否" --> X0["revert"]
    B -- "是" --> C{"topic exists?"}
    C -- "否" --> X1["revert TopicNotFound"]
    C -- "是" --> D{"monthlyPriceWad == 0?"}
    D -- "是" --> X2["revert FreeTopicNoPaymentRequired"]
    D -- "否" --> E{"beneficiary 白名单?"}
    E -- "是" --> X3["revert WhitelistedUserNoPaymentRequired"]
    E -- "否" --> F{"payToken 类型"}

    F -- "BNB (address(0))" --> G["校验 msg.value == amountIn<br/>raw/effective = quoteBnbValueWad"]
    F -- "RAMBLE" --> H["safeTransferFrom(msg.sender -> this)<br/>effective = swapRambleToBnb(amountIn)"]
    F -- "已启用稳定币" --> I["preview stable value<br/>effective = toWad(amountIn, tokenDecimals)<br/>safeTransferFrom(msg.sender -> this)"]
    F -- "其他" --> X4["revert UnsupportedPayToken"]

    G --> J{"effective >= monthlyPriceWad?"}
    H --> J
    I --> J
    J -- "否" --> X5["revert MinimumPaymentNotMet"]
    J -- "是" --> K["secondsAdded = effective * 30days / monthlyPriceWad"]
    K --> L["newExpiry = max(oldExpiry, now) + secondsAdded"]
    L --> M["写入 expiry 并发 Topup 事件"]
```

## 4. RAMBLE 真实兑换路径（交易内结算）
```mermaid
flowchart TD
    A["读取 rambleWbnbPair"] --> B{"pair 地址有效且有代码?"}
    B -- "否" --> X0["revert RamblePairNotConfigured"]
    B -- "是" --> C["读取 token0/token1/reserves"]
    C --> D{"pair 包含 RAMBLE 且储备>0?"}
    D -- "否" --> X1["revert PairTokenMismatch/PairLiquidityTooLow"]
    D -- "是" --> E["RAMBLE 转入 pair"]
    E --> F["计算 amountInActual 与 expectedWbnbOut"]
    F --> G{"expectedWbnbOut > 0?"}
    G -- "否" --> X2["revert PairLiquidityTooLow"]
    G -- "是" --> H["调用 pair.swap 拿到 WBNB"]
    H --> I{"wrappedReceived > 0?"}
    I -- "否" --> X3["revert PairLiquidityTooLow"]
    I -- "是" --> J["调用 WBNB.withdraw(wrappedReceived)"]
    J --> K{"withdraw 成功?"}
    K -- "否" --> X4["revert WrappedNativeWithdrawFailed"]
    K -- "是" --> L["rawValueWad = quoteBnbValueWad(wrappedReceived)"]
    L --> M["effectiveValueWad = rawValueWad * 10000 / discountBps"]
    M --> N{"effective >= monthlyPriceWad?"}
    N -- "否" --> X5["revert MinimumPaymentNotMet(整笔回滚)"]
    N -- "是" --> O["进入 expiry 增量结算"]
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

## 6. 运维应急流程（暂停与恢复）
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

## 7. 使用说明
- 以上流程图与 `05-operations.md` 的 runbook 一一对应。
- 如果图与实现不一致，以合约行为与测试结果为准，并回改本文档。
