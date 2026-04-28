# BSC Topic 权限合约实现文档（v1.8）

关联文档：`../README.md`、`../governance/document-layout.md`、`../requirements/product-requirements.md`、`../design/architecture.md`、`../design/storage-layout.md`、`../design/flowcharts.md`、`../operations/runbook.md`

## 1. 实现目标
- 使用 Foundry 完整落地 `FR-* / NFR-* / AT-*`。
- 输出可复用脚本：部署、升级。
- 输出完整测试：功能 + 安全 + 升级 + 生命周期 + fuzz。

## 2. 当前工程结构（Foundry）
```text
packages/auth-contract/
  .github/
    workflows/
      ci.yml
  foundry.toml
  src/
    TopicAccessManagerUpgradeable.sol
    interfaces/
      IAggregatorV3.sol
      IPancakePairV2.sol
    libraries/
      WadScaleLib.sol
    mocks/
      MockERC20.sol
      MockAggregatorV3.sol
      MockFeeOnTransferERC20.sol
      MockPancakePairV2.sol
      MockWBNB.sol
      TestERC1967Proxy.sol
      TopicAccessManagerUpgradeableV2.sol
      ReentrantExecutorTarget.sol
      WadScaleHarness.sol
  script/
    Deploy.s.sol
    PostDeployConfigure.s.sol
    Upgrade.s.sol
    UpgradeAndMigrate.s.sol
  test/
    base/
      TestBase.sol
      TopicAccessFixture.sol
    unit/
      TopicAccessManager.Unit.t.sol
    fork/
      TopicAccessManager.Fork.t.sol
    security/
      TopicAccessManager.Guardrails.t.sol
      TopicAccessManager.Security.t.sol
    upgrade/
      TopicAccessManager.Upgrade.t.sol
    lifecycle/
      TopicAccessManager.OpsLifecycle.t.sol
    fuzz/
      TopicAccessManager.Fuzz.t.sol
  docs/
    README.md
    governance/
      document-layout.md
    requirements/
      product-requirements.md
    design/
      architecture.md
      storage-layout.md
      flowcharts.md
    implementation/
      implementation-guide.md
    operations/
      runbook.md
    security/
      security-audit.md
    testing/
      ops-lifecycle-testing.md
```

## 3. 分阶段实现
### Phase 1
- 合约骨架、初始化、UUPS 授权。

### Phase 2
- Topic + 白名单 + 鉴权。

### Phase 3
- 计费与报价（BNB / RAMBLE / 通用 payment token）。
- RAMBLE 充值走真实 V2 swap，按交易内实际收到 BNB 结算并应用折扣。
- 保护版充值入口：支持 `minEffectiveValueWad + deadline`。
- ERC20 按实际到账数量结算，避免 fee-on-transfer 记账偏大。
- `setPaymentToken` 支持后置绑定 token 与对应 USD oracle。

### Phase 4
- 风控与特权调用安全边界。
- Oracle 配置前置体检（地址、接口、当前数据有效性）。

### Phase 4A
- Topic registry（`getTopicCount/getTopicAt/getTopicKey`）与 `setTopicKey` 回填。

### Phase 4B
- 全局试用期与 topic 试用期。
- 试用期内 `hasAccess=true`，`topup/quote` 关闭收费路径。

### Phase 5
- 升级回归与 fuzz。
- GitHub Actions CI。
- BSC 主网 fork 用例。

## 4. WAD 与跨链实现要点
- `WAD` 仅内部记账单位，天然兼容多 EVM 链。
- 跨链迁移只需替换 RAMBLE 常量地址/默认 Pair 常量、oracle 与 delay 配置。
- payment token 通过 `setPaymentToken` 动态注册，decimals 由链上自动读取并缓存，避免手工参数错误。
- 稳定币兼容路径通过 `setStableToken` 保留，内部仍复用 payment token 存储。

## 5. 需求-测试映射
- `AT-01` -> `unit/TopicAccessManager.Unit.t.sol`（topicKey hash）
- `AT-02` -> `unit/TopicAccessManager.Unit.t.sol`（free topic）
- `AT-03` -> `unit/TopicAccessManager.Unit.t.sol`（whitelist）
- `AT-03A` -> `unit/TopicAccessManager.Unit.t.sol`（global/topic trial）
- `AT-04` -> `unit/TopicAccessManager.Unit.t.sol`（topup/expiry）
- `AT-04A/AT-04B` -> `unit/TopicAccessManager.Unit.t.sol`、`security/TopicAccessManager.Guardrails.t.sol`（minEffective/deadline）
- `AT-05` -> `fuzz/TopicAccessManager.Fuzz.t.sol`（多精度）
- `AT-05A` -> `unit/TopicAccessManager.Unit.t.sol`、`security/TopicAccessManager.Guardrails.t.sol`（实际到账结算）
- `AT-05B` -> `unit/TopicAccessManager.Unit.t.sol`、`fork/TopicAccessManager.Fork.t.sol`（oracle token quote/topup）
- `AT-06` -> `fuzz/TopicAccessManager.Fuzz.t.sol`（rounding）
- `AT-07` -> `security/TopicAccessManager.Security.t.sol`（oracle 异常）
- `AT-07A` -> `security/TopicAccessManager.Guardrails.t.sol`（payment token oracle 配置错误）
- `AT-08` -> `security/TopicAccessManager.Security.t.sol`（特权调用授权边界）
- `AT-09` -> `security/TopicAccessManager.Security.t.sol`（pause）
- `AT-10` -> `upgrade/TopicAccessManager.Upgrade.t.sol`（升级保状态）
- `AT-11` -> `security/TopicAccessManager.Security.t.sol`（owner 默认特权权限 + executor 后置配置）
- `AT-12` -> `security/TopicAccessManager.Guardrails.t.sol`（稳定币禁用后不可支付）
- `AT-13` -> `unit/TopicAccessManager.Unit.t.sol`（RAMBLE 常量地址与默认折扣）
- `AT-14` -> `unit/TopicAccessManager.Unit.t.sol`、`upgrade/TopicAccessManager.Upgrade.t.sol`（topic registry）
- `AT-15` -> `fork/TopicAccessManager.Fork.t.sol`（真实 BSC token/oracle）
- 额外 guardrails -> `security/TopicAccessManager.Guardrails.t.sol`（配置错误/异常路径）
- 运维生命周期串联 -> `lifecycle/TopicAccessManager.OpsLifecycle.t.sol`（部署配置、运行、应急、升级迁移、连续性）

## 6. 部署与升级（Foundry）
1. 部署：`forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast`
2. 部署后批量配置（推荐）：`forge script script/PostDeployConfigure.s.sol --rpc-url <RPC> --broadcast`
3. 升级：`forge script script/Upgrade.s.sol --rpc-url <RPC> --broadcast`
4. 升级并自动迁移旧稳定币（旧版推荐）：`forge script script/UpgradeAndMigrate.s.sol --rpc-url <RPC> --broadcast`
5. 部署后按需执行：
   - `setExecutors(executorA, executorB)`
   - `setPaymentToken(token, true, usdOracle)`（如 WETH/WBNB/BTCB）
   - `setStableToken(stableToken, true)`
   - `setGlobalTrialEndsAt(trialEndsAt)` / `setTopicTrialEndsAt(topicId, trialEndsAt)`
   - `setRamblePair(rambleWbnbPair)`（若需覆盖默认常量）
   - `setTopicKey(topicId, topicKey)`（若 topic 先按裸 `topicId` 创建）
6. `PostDeployConfigure.s.sol` 支持：
   - 默认批量启用 BSC 主网 `WETH/USDT/USDC/WBNB/BTCB`
   - 通过 `GLOBAL_TRIAL_ENDS_AT` 设置/清空全局试用期
   - 通过 `TOPIC_TRIAL_KEYS` 与 `TOPIC_TRIAL_ENDS_ATS` 批量设置 topic 试用期
7. 升级前检查：
   - `forge test --offline -vv`
   - 升级回归测试通过
   - storage 仅追加
8. 升级后检查：
   - topic/expiry/whitelist/discount/config 状态一致
   - hasAccess/topup/quote/privilegedCall 正常

## 7. 安全检查清单
- onlyOwner 边界。
- 特权调用授权边界（owner / executorA / executorB）。
- `nonReentrant` 对重入攻击路径有效。
- oracle stale / invalid round 拒绝。
- free topic & whitelist 不可误收费。
- privileged call 禁止 `target=0/this`。
- 稳定币 decimals 自动读取 + 上限校验。
- 未注册稳定币不可支付。
- 设置 RAMBLE Pair 时前置校验 Pair 必须包含 RAMBLE。
- 设置 RAMBLE Pair 时校验对手币支持 `withdraw(uint256)`，确保可解包为原生 BNB。
- RAMBLE Pair 无代码时路径显式失败。
- UUPS 升级仅 owner 可执行，升级后状态保真。
- 事件字段最小化，避免日志冗余。

## 8. 常用命令
- `forge build`
- `forge test --offline -vv`
- `forge test --offline --match-path test/security/*.t.sol -vv`
- `forge test --offline --match-path test/upgrade/*.t.sol -vv`
- `forge test --offline --match-path test/lifecycle/*.t.sol -vv`
- `forge test --offline --match-path test/fuzz/*.t.sol -vv`
- `BSC_RPC_URL=<RPC> forge test --match-path test/fork/*.t.sol -vv`
- `forge script script/PostDeployConfigure.s.sol --rpc-url <RPC> --broadcast`
- `forge coverage --offline --report summary`
- `npm run -w @omniarb/auth-contract check:security`
- `npm run -w @omniarb/auth-contract ci`
- `npm run -w @omniarb/auth-contract test:lifecycle`
- `forge script script/UpgradeAndMigrate.s.sol --rpc-url <RPC> --broadcast`
- `forge fmt`
- `forge clean`

## 9. 覆盖率快照
- 执行命令：`forge coverage --offline --report summary`
- 说明：`script/*.s.sol` 通常不计入单元测试覆盖，新增 `UpgradeAndMigrate.s.sol` 会拉低项目总体覆盖率，但不影响核心合约覆盖趋势。
- 核心合约 `src/TopicAccessManagerUpgradeable.sol`：
  - Lines: `91.15%` (412/452)
  - Statements: `91.54%` (433/473)
  - Branches: `68.60%` (59/86)
  - Funcs: `96.05%` (73/76)
- 项目总体：
  - Lines: `85.80%` (562/655)
  - Statements: `84.93%` (569/670)
  - Branches: `62.04%` (67/108)
  - Funcs: `92.56%` (112/121)

## 10. 流程图映射
- 鉴权流程：`../design/flowcharts.md` 第 2 节
- 充值主流程：`../design/flowcharts.md` 第 3 节
- RAMBLE 真实兑换：`../design/flowcharts.md` 第 4 节
- 升级迁移：`../design/flowcharts.md` 第 5 节

## 11. 存储布局映射
- 存储基线快照：`../design/storage-layout.md` 第 3 节
- 升级约束：`../design/storage-layout.md` 第 4 节

## 12. DoD
- `forge build` 通过。
- `forge test --offline` 全绿。
- 升级回归与安全检查覆盖完成。
- GitHub Actions CI 与本地 `npm run ci` 可复用。
- 文档全集（含 layout 与流程图）与代码一致。
