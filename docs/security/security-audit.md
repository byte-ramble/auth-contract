# BSC Topic 权限合约安全审计与加固记录（v1.7）

关联文档：`../requirements/product-requirements.md`、`../design/architecture.md`、`../design/storage-layout.md`、`../design/flowcharts.md`、`../implementation/implementation-guide.md`、`../operations/runbook.md`

## 1. 审计范围
- 主合约：`src/TopicAccessManagerUpgradeable.sol`
- 核心库：`src/libraries/WadScaleLib.sol`
- 关键测试：`test/security/*`、`test/upgrade/*`、`test/lifecycle/*`、`test/fuzz/*`

## 2. 审计方法
- 静态代码审阅：权限边界、资金路径、升级入口、配置一致性、价格路径。
- 动态测试：功能/安全/升级/生命周期/fuzz 全量回归。
- 覆盖率检查：`forge coverage --offline --report summary`。

## 3. 审计结论
- 当前版本未发现会导致直接资金损失的高危缺陷。
- 已完成一轮安全加固，重点收敛了配置错误导致的风险敞口。
- 核心合约覆盖率达：Lines `92.60%`，Statements `92.80%`，Branches `70.97%`，Funcs `97.75%`。

## 4. 发现与修复
### 4.1 已修复
1. `MEDIUM`：初始化参数过多、token 依赖初始化注入，易引入部署误配置。  
   修复：`initialize` 精简为 `owner + oracle + delay`；稳定币改为后置 `setStableToken` 动态注册。

2. `MEDIUM`：RAMBLE Pair 错配仅在运行期（topup/quote）才暴露。  
   修复：`setRamblePair` 增加前置校验，Pair 必须包含 RAMBLE。

3. `MEDIUM`：RAMBLE 地址与默认参数可由初始化输入，存在被错误/恶意注入的风险。  
   修复：RAMBLE 地址、默认 Pair、默认折扣改为合约常量，并保留 owner 维护入口。

4. `MEDIUM`：RAMBLE 仅做估值不做真实兑换，可能与实际成交偏离。  
   修复：`topup` 的 RAMBLE 路径改为真实执行 V2 `swap`，按实际收到 BNB 计算价值并校验月费。

5. `MEDIUM`：旧版升级后若遗漏稳定币重新注册，可能导致支付中断。  
   修复：新增 `UpgradeAndMigrate.s.sol`，通过 `getLegacyStableTokens` 自动迁移 legacy 稳定币配置。

6. `LOW`：稳定币估值路径有重复代码，增加维护错误概率。  
   修复：抽取 `_quoteStableValueWad` 统一逻辑。

7. `LOW`：安全测试脚本 glob 在多文件时会被 shell 展开，导致命令异常。  
   修复：`package.json` 中 `--match-path` 改为带引号模式，保证 `check:security` 稳定执行。

8. `LOW`：错误路径覆盖不足。  
   修复：新增 `test/security/TopicAccessManager.Guardrails.t.sol`，覆盖配置错误、支付错误、oracle/pair 异常、topic 边界等路径。

9. `LOW`：事件日志字段过多，增加索引与解析噪音。  
   修复：事件统一裁剪为最小必要字段，保留审计与账务追踪所需核心信息。

10. `MEDIUM`：用户按预览值提交充值时，执行阶段缺少最小结算值与超时保护，RAMBLE 与 fee-on-transfer 稳定币路径容易出现不可控到账偏差。  
   修复：新增保护版 `topup(..., minEffectiveValueWad, deadline)`；稳定币改为按合约实际到账数量计费。

11. `LOW`：topic 只保留 `topicId`，链上缺少 registry，不利于后台同步、巡检与升级后核验。  
   修复：新增 `topicIds[] + topicKeyById`、`getTopicCount/getTopicAt/getTopicKey` 与 `setTopicKey` 回填接口。

12. `LOW`：oracle 错配需要等到 `quote/topup` 才暴露。  
   修复：`setOracleConfig` 增加地址有代码、接口可读、当前数据有效性的前置检查。

13. `MEDIUM`：只支持“稳定币 1:1 USD”模型，不利于后续扩展 WETH/WBNB/BTCB 等按 oracle 计价的支付代币。  
   修复：新增 `setPaymentToken(token, enabled, usdOracle)` 与 `getPaymentTokenConfig/quoteMinTokenForOneMonth`；payment token 可按 token/USD oracle 定价。

14. `LOW`：活动期、拉新期等场景需要免费试用，但旧模型只能依赖白名单或免费 topic，运维粒度不够。  
   修复：新增全局试用期与 topic 试用期；试用期内 `hasAccess=true`，同时阻断收费型 `topup`。

15. `LOW`：本地 mock 不能覆盖真实 BSC token/oracle 地址与 decimals 组合。  
   修复：新增 `test/fork/TopicAccessManager.Fork.t.sol`，对真实 `WETH/USDT/USDC/WBNB/BTCB` 与对应 USD oracle 做 fork 验证。

16. `LOW`：RAMBLE 常量与默认 Pair 都指向 BSC，如果在非 BSC 链误开放 RAMBLE 入口，错误会在运行期表现为配置/流动性异常，运维语义不清晰。  
   修复：新增 `BSC_CHAIN_ID=56` 与 `RambleOnlySupportedOnBsc` 守卫；非 BSC 链初始化时不写默认 RAMBLE Pair，且 RAMBLE 的 quote/preview/topup/setRamblePair 全部显式失败。

17. `MEDIUM`：topic 缺少支付路由级控制，异常 token 或特定 topic 的支付策略只能依赖全局 pause 或共享配置绕行。  
   修复：新增 topic 级 payment allowlist；`topup/quote/preview` 共用同一 `payToken` 准入规则，`address(0)` 仍表示原生 BNB，无需额外硬编码地址。

18. `MEDIUM`：缺少精确的运营纠偏原语，人工补偿、迁移修正只能借助白名单或试用期，粒度过粗。  
   修复：新增 `setExpiry/extendExpiry` 与 `ExpiryUpdated` 事件，允许 owner 对单个 `topicId + user` 的 expiry 做精确修正。

19. `LOW`：payment token 元数据的读写散落在多组并行 mapping 中，后续维护容易继续扩散。  
   修复：新增内部 `PaymentTokenConfig` 抽象，统一 payment token 配置读写入口，降低后续扩展时的耦合度。

20. `CRITICAL`：存储布局文档（`storage-layout.md` v1.2）严重过期：OZ v5 迁移后 `_initialized`/`_initializing`/`_status` 改用 ERC-7201 命名空间存储不再占用顺序 slot，导致所有后续变量 slot 偏移；`_stableTokenEnabled/_stableTokenDecimals` 已重命名为 `_paymentTokenEnabled/_paymentTokenDecimals`；新增 `_topicDeactivated`（slot 23）；首发前已移除废弃的 legacy executor 槽位并把该空间回收进 `__gap`。
   修复：重新生成 storage layout 快照，更新为当前发布基线，增加 v1.2 差异摘要与 OZ 非升级版永久约束说明。

21. `HIGH`：部署脚本若把 deployer 私钥直接暴露给日志、环境或 CLI，会放大本机侧泄露面；同时广播必须显式绑定 sender 与签名钱包，避免 Foundry 回退到默认 sender。
   修复：keystore 部署路径改为使用 Foundry 原生 `--keystore + --sender` 签名，不再先把 keystore 解成私钥；仅在显式直连私钥回退模式下才使用 `--private-key`，且日志输出对该参数做脱敏。

22. `HIGH`：部署脚本使用 `--skip-simulation` 跳过 `eth_call` 模拟，revert 交易直接上链浪费 gas。
   修复：移除 `--skip-simulation` 标志。

23. `LOW`：部署脚本无 deployer BNB 余额预检查，可能在余额不足时浪费 gas。
   修复：新增 `checkDeployerBalance` 在部署前检查余额。

24. `LOW`：部署后未在 BSCScan 验证源码。
   修复：新增 `verifyContract` 工具函数与 `deploy:verify` action。

25. `LOW`：无资金提取 SOP，合约累积的 BNB/ERC20 提取依赖隐式的高权限调用知识。
   修复：在 `runbook.md` 新增资金提取 SOP（第 8 节），并提供 `withdrawNative/withdrawERC20` 作为标准提取路径；`executePrivilegedCall` 保留给通用治理调用。

### 4.2 残余风险（设计接受项）
1. 特权 `executePrivilegedCall` 本质是高权限后门能力，属于治理风险而非实现漏洞。  
   建议：owner 使用多签，executor 采用最小权限地址，并接入告警。

2. BSC 上 RAMBLE 估值依赖单一 Pair 的储备与预言机价格，存在流动性薄弱时的估值波动风险。  
   建议：前端统一走带 `minEffectiveValueWad + deadline` 的保护版 `topup`，运营侧设置 topic 月费下限、监控 Pair 储备变化，并在高风险 topic 上启用 payment allowlist。

3. 升级权限集中于 owner。  
   建议：升级流程接入 timelock + 多签审批，执行前后固定跑 `check:security` 与升级回归。

4. 使用 `setStableToken` 的 1:1 USD 路径，本质仍信任 owner 对“稳定币”属性的业务判断。  
   建议：对非明确锚定美元的 token 一律使用 `setPaymentToken(..., usdOracle)`，不要走稳定币兼容入口。

5. 真实 fork 测试在部分 macOS Foundry 环境下可能被系统代理崩溃阻断。  
   建议：将 `test:fork` 作为 Linux CI 或无代理 shell 的预发布步骤，而不是只依赖本机运行。

## 5. 回归验证
- `forge test --offline -vv`：`85` passed, `0` failed
- `npm run check:security`：通过（含 `test:lifecycle`）
- `forge coverage --offline --report summary`：通过
- `npm run fmt:check`：通过
- `npm run ci`：通过（含 `fmt/build/test/coverage`）
- `BSC_RPC_URL=<RPC> forge test --match-path "test/fork/*.t.sol"`：当前仓库已有真实 BSC fork 用例；若本机受 Foundry/macOS 网络环境影响，建议转 Linux CI 或无代理 shell 执行

## 6. v1.7 审计修复清单（2026-04-06）
| # | 严重性 | 修复内容 | 文件 |
|---|--------|----------|------|
| 20 | CRITICAL | 存储布局文档重新生成 v2.0 | `storage-layout.md` |
| 21 | HIGH | 私钥改用环境变量传递 | `deploy/shared.mjs` |
| 22 | HIGH | 移除 `--skip-simulation` | `deploy/shared.mjs` |
| 23 | LOW | 添加 deployer 余额预检查 | `deploy/shared.mjs`, `deploy/deploy.mjs` |
| 24 | LOW | 添加 BSCScan 验证 action | `deploy/shared.mjs`, `deploy/deploy.mjs` |
| 25 | LOW | 添加资金提取 SOP | `docs/operations/runbook.md` |
| — | MEDIUM | OZ 非升级版永久约束文档化 | `storage-layout.md`, `architecture.md` |
