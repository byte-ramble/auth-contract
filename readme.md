# auth-contract

文档统一在 `docs/`：

- `docs/README.md`：文档总索引
- `docs/00-doc-layout.md`：文档 layout 与维护规则
- `docs/01-requirements.md`：需求文档
- `docs/02-design.md`：设计文档
- `docs/06-flowcharts.md`：详细流程图
- `docs/03-implementation.md`：实现文档
- `docs/05-operations.md`：运维文档
- `docs/04-security-audit.md`：安全审计与加固记录

当前实现：纯 Foundry 工程。

关键约束：
- Topic 标识：`topicId = keccak256(bytes(topicKey))`
- 计费单位：`WAD(1e18)`
- 精度策略：适配任意常见 token decimals（统一归一化）
- RAMBLE 地址与默认 Pair：合约常量硬编码
- 稳定币配置：`setStableToken(token, enabled)` 自动读取链上 decimals 并校验上限
- 升级模式：UUPS（`ERC1967Proxy + upgradeTo`）
- 特权调用：owner 默认可调用；executorA/executorB 通过 `setExecutors` 后置配置

常用命令：
- `npm run -w @omniarb/auth-contract build`
- `npm run -w @omniarb/auth-contract test`
- `npm run -w @omniarb/auth-contract check:security`
- `forge script script/UpgradeAndMigrate.s.sol --rpc-url <RPC> --broadcast`
- `forge test --offline -vv --root packages/auth-contract`

说明：测试命令默认使用 `--offline`，用于规避部分系统代理环境下的 Foundry 运行时崩溃。
# auth-contract
