# BSC Topic 权限合约运维文档（v1.2）

关联文档：`../README.md`、`../governance/document-layout.md`、`../design/flowcharts.md`、`../design/storage-layout.md`、`../implementation/implementation-guide.md`、`../security/security-audit.md`、`../testing/ops-lifecycle-testing.md`

## 1. 目标
- 提供可执行的部署、升级、迁移、回滚与应急 runbook。
- 降低升级后配置遗漏（尤其 payment token / trial 配置）风险。

## 1.1 流程图入口
- 生命周期总流程：`../design/flowcharts.md` 第 1 节
- 升级与迁移流程：`../design/flowcharts.md` 第 5 节
- 应急暂停与恢复流程：`../design/flowcharts.md` 第 6 节

## 2. 角色分工
- 运维执行人：按 runbook 执行命令与链上操作。
- 审批人（建议多签）：审批升级与特权调用。
- 观察人：执行后核验关键状态与告警面板。

## 3. 环境准备
- 工具：
  - Foundry（`forge`）
  - 可签名账户（owner 或 owner 多签执行器）
- 必要环境变量：
  - `OWNER`
  - `BNB_USD_ORACLE`
  - `MAX_ORACLE_DELAY`
  - `PROXY_ADDRESS`（升级/迁移时）
- 可选环境变量：
  - `BSC_RPC_URL`（发布前执行真实链上 fork 验证时）
- 推荐前置检查：
  - `npm run -w @omniarb/auth-contract fmt:check`
  - `npm run -w @omniarb/auth-contract test`
  - `npm run -w @omniarb/auth-contract check:security`
  - `npm run -w @omniarb/auth-contract ci`
  - `npm run -w @omniarb/auth-contract test:lifecycle`

## 4. 首次部署 Runbook
1. 部署 proxy + implementation：
   - `forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast`
2. 推荐的批量配置脚本：
   - `forge script script/PostDeployConfigure.s.sol --rpc-url <RPC> --broadcast`
   - 关键环境变量：
     - `PROXY_ADDRESS`
     - `CONFIGURE_BSC_PAYMENT_TOKENS=true|false`（默认 `true`）
     - `GLOBAL_TRIAL_ENDS_AT`
     - `TOPIC_TRIAL_KEYS=topic.a,topic.b`
     - `TOPIC_TRIAL_ENDS_ATS=1735689600,1738291200`
3. 部署后初始化配置（按业务需要）：
   - `setExecutors(executorA, executorB)`
   - `setPaymentToken(token, true, usdOracle)`（非稳定币或希望显式绑定 oracle 的 token）
   - `setStableToken(stableToken, true)`（1:1 USD 稳定币兼容入口，可重复调用添加多个）
   - `setGlobalTrialEndsAt(trialEndsAt)` / `setTopicTrialEndsAt(topicId, trialEndsAt)`
   - `setRamblePair(pair)`（仅在需要覆盖默认常量时）
   - `setTopicKey(topicId, topicKey)`（若 topic 通过 `createTopic` 创建）
   - BSC 主网推荐样例：
     - `WETH -> ETH/USD`
     - `USDT -> USDT/USD`
     - `USDC -> USDC/USD`
     - `WBNB -> BNB/USD`
     - `BTCB -> BTC/USD`
4. 验证：
   - `getOracleConfig` 与配置一致
   - `getPaymentTokenConfig(token)` 与预期一致
   - `getStableTokenConfig(token).enabled == true`
   - `getGlobalTrialEndsAt/getTopicTrialEndsAt/getEffectiveTrialEndsAt` 与业务策略一致
   - `getRamblePair` 与预期一致
   - `getTopicCount/getTopicAt/getTopicKey` 可读
   - 使用带 `minEffectiveValueWad + deadline` 的 `topup` 做小额冒烟（BNB / payment token / RAMBLE）

## 5. 升级 Runbook（无迁移）
1. 部署新实现并升级：
   - `forge script script/Upgrade.s.sol --rpc-url <RPC> --broadcast`
2. 升级后验证：
   - topic/expiry/whitelist/trial/payment token 状态保持
   - `hasAccess`、`topup`、`quote` 正常
   - `owner`、`executor` 权限边界不变

## 6. 升级+迁移 Runbook（旧版推荐）
适用：从旧版本升级到当前版本，并自动迁移旧 `_usdc/_usdt` 为新稳定币注册。

1. 执行升级并迁移：
   - `forge script script/UpgradeAndMigrate.s.sol --rpc-url <RPC> --broadcast`
2. 脚本行为：
   - 部署新 implementation
   - 对 proxy 执行 `upgradeTo`
   - 调用 `getLegacyStableTokens()` 读取旧版稳定币地址
   - 对有效 token 自动执行 `setStableToken(token, true)`
3. 自动跳过场景：
   - 地址为 `0`
   - 地址等于 `RAMBLE_TOKEN`
   - 地址无代码
   - 已经启用的稳定币
4. 升级后核验：
   - `getStableTokenConfig(legacyUsdc).enabled == true`（若 legacyUsdc 有效）
   - `getStableTokenConfig(legacyUsdt).enabled == true`（若 legacyUsdt 有效）
   - 抽样执行稳定币 `topup`

## 7. 失败处理与回滚
- 脚本交易失败：
  - 先确认调用账户是否具备 owner 权限。
  - 检查 `PROXY_ADDRESS` 是否正确，RPC 是否可用。
  - 根据 revert 原因修正后重试（幂等）。
- 升级后稳定币未迁移：
  - 手动执行 `setStableToken(token, true)` 补齐。
- 升级后 payment token / 试用期未配置：
  - 手动执行 `setPaymentToken` / `setGlobalTrialEndsAt` / `setTopicTrialEndsAt` 补齐。
- 回滚策略：
  - 通过 owner 将 proxy 升级到上一个已验证实现。
  - 回滚前后均执行最小回归（`hasAccess/topup/quote`）。

## 8. 资金提取 SOP

合约通过 `topup` 收集的 BNB 和 ERC20 代币，只能通过 `executePrivilegedCall` 提取。
调用者需为 owner 或 executor。

### 8.1 提取 BNB

```solidity
// 通过 cast 或 multisig 执行
executePrivilegedCall(
    recipientAddress,   // target: 接收地址
    amountInWei,        // value: 提取金额（Wei）
    ""                  // data: 空
)
```

**cast 示例**：
```bash
cast send <PROXY_ADDRESS> \
  "executePrivilegedCall(address,uint256,bytes)" \
  <RECIPIENT> <AMOUNT_WEI> "0x" \
  --rpc-url <BSC_RPC_URL> --private-key <KEY>
```

### 8.2 提取 ERC20 代币

```solidity
executePrivilegedCall(
    tokenAddress,       // target: 代币合约地址
    0,                  // value: 0
    abi.encodeCall(IERC20.transfer, (recipientAddress, tokenAmount))
)
```

**cast 示例**：
```bash
cast send <PROXY_ADDRESS> \
  "executePrivilegedCall(address,uint256,bytes)" \
  <TOKEN_ADDRESS> 0 \
  $(cast calldata "transfer(address,uint256)" <RECIPIENT> <AMOUNT>) \
  --rpc-url <BSC_RPC_URL> --private-key <KEY>
```

### 8.3 查询合约余额

```bash
# BNB 余额
cast balance <PROXY_ADDRESS> --rpc-url <BSC_RPC_URL>

# ERC20 余额
cast call <TOKEN_ADDRESS> "balanceOf(address)" <PROXY_ADDRESS> --rpc-url <BSC_RPC_URL>
```

### 8.4 提取注意事项
- 建议通过多签执行，避免单点密钥风险。
- 每次提取后核对合约余额与 `Topup` 事件日志。
- `executePrivilegedCall` 执行成功后会发出 `PrivilegedCallExecuted` 事件，可用于审计。
- 不要将合约余额提取到 0，保留少量 BNB 以便后续 RAMBLE swap 的 WBNB unwrap 回调。

## 9. 日常运维检查
- 配置一致性：
  - `getOracleConfig`、`getRamblePair`、`getRambleDiscountBps`
  - `getPaymentTokenConfig` 是否符合业务 token 清单
  - `getGlobalTrialEndsAt/getTopicTrialEndsAt/getEffectiveTrialEndsAt` 是否符合当前活动策略
  - `getTopicCount/getTopicAt/getTopicKey` 与后台 topic 清单一致
  - 稳定币白名单是否符合业务清单
- 风险监控：
  - Chainlink 数据是否 stale
  - RAMBLE Pair 储备是否异常下降
  - 合约余额与提取日志对账
- 发布前建议：
  - `BSC_RPC_URL=<RPC> npm run -w @omniarb/auth-contract test:fork`
  - 若本机 Foundry 在 macOS 上因系统代理崩溃，改用 Linux CI 或无代理 shell 执行真实 fork
- 应急措施：
  - 异常时 owner 执行 `pause()`
  - 完成排障后 `unpause()`
