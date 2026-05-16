# auth-contract

文档统一在 `docs/`：

- `docs/README.md`：文档总索引
- `docs/governance/document-layout.md`：文档 layout 与维护规则
- `docs/requirements/product-requirements.md`：需求文档
- `docs/design/architecture.md`：设计文档
- `docs/design/storage-layout.md`：存储布局基线
- `docs/design/flowcharts.md`：详细流程图
- `docs/implementation/implementation-guide.md`：实现文档
- `docs/operations/runbook.md`：运维文档
- `docs/security/security-audit.md`：安全审计与加固记录
- `docs/testing/ops-lifecycle-testing.md`：运维周期测试覆盖文档

当前实现：纯 Foundry 工程。

关键约束：
- Topic 标识：`topicId = keccak256(bytes(topicKey))`
- 计费单位：`WAD(1e18)`
- 精度策略：适配任意常见 token decimals（统一归一化）
- 推荐充值入口：使用带 `minEffectiveValueWad + deadline` 的保护版 `topup`
- 支付币种：支持 `BNB / RAMBLE / owner 后置配置的 ERC20 payment token`
- RAMBLE 折扣：默认 `9000 bps`，即 RAMBLE 充值按 9 折计入会员支付价值
- RAMBLE 限制：仅在 `BSC chainId=56` 生效；非 BSC 链上 `quote/preview/topup/setRamblePair` 会显式回滚
- `setPaymentToken(token, enabled, usdOracle)` 支持为单个支付代币绑定 USD 预言机；`setStableToken(token, enabled)` 保留为兼容性的 1:1 USD wrapper
- ERC20 按“合约实际到账数量”计费，兼容 fee-on-transfer 场景的保守结算
- 试用期：支持全局与单个 topic 维度免费试用；试用期内 `hasAccess=true`，`topup/quote` 不再要求支付
- Topic 支付策略：支持 topic 级 payment allowlist；`address(0)` 表示原生 BNB，allowlist 未启用时保持历史默认可支付行为
- 运营纠偏：owner 可通过 `setExpiry/extendExpiry` 精确补偿、迁移或手动修正单个用户订阅期
- 结构优化：主合约保留状态、权限与资金流；策略判断和 RAMBLE 纯计算拆到内部库，降低单文件复杂度
- Topic registry：提供 `getTopicCount/getTopicAt/getTopicKey` 便于链下后台同步
- RAMBLE 地址与默认 Pair：合约常量硬编码
- 支付代币配置：启用时自动读取链上 decimals 并校验上限；带 oracle 的 token 在配置时做前置体检
- Oracle 配置：`setOracleConfig` 会前置校验 oracle 地址、接口与当前数据有效性
- 升级模式：UUPS（`ERC1967Proxy + upgradeTo`）
- 特权提取：owner 默认可调用；单一 `executor` 通过 `setExecutor` 后置配置；标准资产提取走 `withdrawNative/withdrawERC20`
- BSC 主网样例已覆盖 `WETH/USDT/USDC/WBNB/BTCB` + 对应 USD oracle 的 fork 用例
- CI：内置 GitHub Actions；本地 `npm run ci` 与 Actions 对齐执行 `fmt/build/test/coverage`

常用命令：
- `npm run build`
- `npm run test`
- `npm run test:fork`
- `npm run check:security`
- `npm run ci`
- `npm run test:lifecycle`
- `npm run prepare:membership-payments`
- `npm run deploy:implementation`
- `forge script script/PostDeployConfigure.s.sol --rpc-url <RPC> --broadcast`
- `forge script script/UpgradeAndMigrate.s.sol --rpc-url <RPC> --broadcast`
- `forge test --offline -vv --root packages/auth-contract`

说明：
- `PostDeployConfigure.s.sol` 会在 `TOPIC_KEY` / `TOPIC_PRICE_WAD` 存在时幂等创建或更新 topic，并在 `TOPIC_ANNUAL_PRICE_WAD` 存在时设置年费价格。
- 默认测试命令使用 `--offline`，用于规避部分系统代理环境下的 Foundry 运行时崩溃。
- 真实链上 fork 用例需要 `BSC_RPC_URL=<RPC> npm run test:fork`。
- 当前环境下，Foundry 对联网 fork 存在 macOS `system-configuration` 崩溃问题；离线测试不受影响。
