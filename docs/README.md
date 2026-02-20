# auth-contract 文档索引

## 文档分层
### L0 治理层
1. `README.md`：全局导航与阅读路径
2. `00-doc-layout.md`：文档分层、职责边界、更新规则

### L1 业务层
3. `01-requirements.md`：需求、约束、接口、验收标准

### L2 架构层
4. `02-design.md`：架构方案、存储布局、升级策略

### L3 流程层
5. `06-flowcharts.md`：详细流程图（鉴权、充值、升级迁移、运维应急）

### L4 实现层
6. `03-implementation.md`：工程结构、测试映射、实现细节

### L5 运维层
7. `05-operations.md`：部署、升级、迁移、回滚、应急 runbook

### L6 安全层
8. `04-security-audit.md`：审计结论、风险与加固记录

## 建议阅读顺序
1. `00-doc-layout.md`
2. `01-requirements.md`
3. `02-design.md`
4. `06-flowcharts.md`
5. `03-implementation.md`
6. `05-operations.md`
7. `04-security-audit.md`

## 文档关系
- `00-doc-layout.md` 定义文档体系与更新规约。
- `01-requirements.md` 是业务与验收基线。
- `02-design.md` 逐条映射 `FR-* / NFR-*` 到可实现架构。
- `06-flowcharts.md` 以流程图描述关键路径，作为需求到实现之间的执行视图。
- `03-implementation.md` 对应代码落地与测试矩阵。
- `05-operations.md` 提供发布与升级迁移流程。
- `04-security-audit.md` 记录审计结果与残余风险。

## 全局一致性约束
- 统一计费单位：`WAD (1e18)`。
- 统一命名后缀：金额/价格字段使用 `...Wad`。
- Topic 主键：`topicId = keccak256(bytes(topicKey))`。
- 鉴权优先级：`topic存在 -> 白名单 -> 免费topic -> expiry`。
- `monthlyPriceWad == 0` 时：`hasAccess=true`，`topup` 必须失败。
- RAMBLE 地址由合约常量定义，不通过初始化注入。
- 稳定币通过 `setStableToken(token, enabled)` 后置注册。
- 旧版升级可使用 `script/UpgradeAndMigrate.s.sol` 自动迁移 legacy 稳定币配置。
- 特权调用权限：`owner` 默认可用，`executorA/B` 由 owner 后置配置。

## 技术栈结论
- 主栈：`Foundry + forge script + forge test`。
- 升级类型：`UUPS Proxy (ERC1967Proxy + upgradeTo)`。
- 安全测试：unit + security + upgrade + fuzz 全覆盖。
- 运行建议：测试命令默认加 `--offline`，避免本机代理配置导致的 Foundry 网络初始化异常。
