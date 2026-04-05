# auth-contract 文档索引

## 文档分层
### L0 治理层
1. `README.md`：全局导航与阅读路径
2. `governance/document-layout.md`：文档分层、职责边界、更新规则

### L1 业务层
3. `requirements/product-requirements.md`：需求、约束、接口、验收标准

### L2 架构层
4. `design/architecture.md`：架构方案、模块划分、升级策略
5. `design/storage-layout.md`：存储槽位布局与升级对照基线

### L3 流程层
6. `design/flowcharts.md`：详细流程图（鉴权、充值、升级迁移、运维应急）

### L4 实现层
7. `implementation/implementation-guide.md`：工程结构、测试映射、实现细节

### L5 运维层
8. `operations/runbook.md`：部署、升级、迁移、回滚、应急 runbook

### L6 安全层
9. `security/security-audit.md`：审计结论、风险与加固记录

### L7 测试层
10. `testing/ops-lifecycle-testing.md`：运维周期测试覆盖矩阵与执行建议

## 建议阅读顺序
1. `governance/document-layout.md`
2. `requirements/product-requirements.md`
3. `design/architecture.md`
4. `design/storage-layout.md`
5. `design/flowcharts.md`
6. `implementation/implementation-guide.md`
7. `operations/runbook.md`
8. `security/security-audit.md`
9. `testing/ops-lifecycle-testing.md`

## 文档关系
- `governance/document-layout.md` 定义文档体系与更新规约。
- `requirements/product-requirements.md` 是业务与验收基线。
- `design/architecture.md` 逐条映射 `FR-* / NFR-*` 到可实现架构。
- `design/storage-layout.md` 提供升级前后 storage layout 对照基线。
- `design/flowcharts.md` 以流程图描述关键路径，作为需求到实现之间的执行视图。
- `implementation/implementation-guide.md` 对应代码落地与测试矩阵。
- `operations/runbook.md` 提供发布与升级迁移流程。
- `security/security-audit.md` 记录审计结果与残余风险。
- `testing/ops-lifecycle-testing.md` 给出完整运维周期覆盖结论与执行建议。

## 全局一致性约束
- 统一计费单位：`WAD (1e18)`。
- 统一命名后缀：金额/价格字段使用 `...Wad`。
- Topic 主键：`topicId = keccak256(bytes(topicKey))`。
- 鉴权优先级：`topic存在 -> 白名单 -> 试用期 -> 免费topic -> expiry`。
- `monthlyPriceWad == 0` 时：`hasAccess=true`，`topup` 必须失败。
- 试用期生效时：`hasAccess=true`，`topup` 必须失败，`quote/preview` 返回 `0`。
- RAMBLE 地址由合约常量定义，不通过初始化注入。
- 支付代币通过 `setPaymentToken(token, enabled, usdOracle)` 后置注册；`setStableToken` 仅保留为 1:1 USD 兼容入口。
- 旧版升级可使用 `script/UpgradeAndMigrate.s.sol` 自动迁移 legacy 稳定币配置。
- 特权调用权限：`owner` 默认可用，`executorA/B` 由 owner 后置配置。
- 真实 BSC fork 用例需要 `BSC_RPC_URL`；缺失时 `test/fork/*.t.sol` 自动跳过。

## 技术栈结论
- 主栈：`Foundry + forge script + forge test`。
- 升级类型：`UUPS Proxy (ERC1967Proxy + upgradeTo)`。
- 安全测试：unit + security + upgrade + fuzz 全覆盖。
- 运行建议：离线测试默认加 `--offline`；真实链上 fork 通过 `test:fork` 单独执行。
