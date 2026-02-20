# BSC Topic 权限合约运维文档（v1.0）

关联文档：`./README.md`、`./00-doc-layout.md`、`./06-flowcharts.md`、`./03-implementation.md`、`./04-security-audit.md`

## 1. 目标
- 提供可执行的部署、升级、迁移、回滚与应急 runbook。
- 降低升级后配置遗漏（尤其稳定币注册）风险。

## 1.1 流程图入口
- 生命周期总流程：`06-flowcharts.md` 第 1 节
- 升级与迁移流程：`06-flowcharts.md` 第 5 节
- 应急暂停与恢复流程：`06-flowcharts.md` 第 6 节

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
- 推荐前置检查：
  - `npm run -w @omniarb/auth-contract fmt:check`
  - `npm run -w @omniarb/auth-contract test`
  - `npm run -w @omniarb/auth-contract check:security`

## 4. 首次部署 Runbook
1. 部署 proxy + implementation：
   - `forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast`
2. 部署后初始化配置（按业务需要）：
   - `setExecutors(executorA, executorB)`
   - `setStableToken(stableToken, true)`（可重复调用添加多个）
   - `setRamblePair(pair)`（仅在需要覆盖默认常量时）
3. 验证：
   - `getOracleConfig` 与配置一致
   - `getStableTokenConfig(token).enabled == true`
   - `getRamblePair` 与预期一致
   - `topup` 小额冒烟（BNB / 稳定币 / RAMBLE）

## 5. 升级 Runbook（无迁移）
1. 部署新实现并升级：
   - `forge script script/Upgrade.s.sol --rpc-url <RPC> --broadcast`
2. 升级后验证：
   - topic/expiry/whitelist 状态保持
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
- 回滚策略：
  - 通过 owner 将 proxy 升级到上一个已验证实现。
  - 回滚前后均执行最小回归（`hasAccess/topup/quote`）。

## 8. 日常运维检查
- 配置一致性：
  - `getOracleConfig`、`getRamblePair`、`getRambleDiscountBps`
  - 稳定币白名单是否符合业务清单
- 风险监控：
  - Chainlink 数据是否 stale
  - RAMBLE Pair 储备是否异常下降
  - 合约余额与提取日志对账
- 应急措施：
  - 异常时 owner 执行 `pause()`
  - 完成排障后 `unpause()`
