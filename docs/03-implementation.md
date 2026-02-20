# BSC Topic 权限合约实现文档（v1.6）

关联文档：`./README.md`、`./00-doc-layout.md`、`./01-requirements.md`、`./02-design.md`、`./06-flowcharts.md`、`./05-operations.md`

## 1. 实现目标
- 使用 Foundry 完整落地 `FR-* / NFR-* / AT-*`。
- 输出可复用脚本：部署、升级。
- 输出完整测试：功能 + 安全 + 升级 + fuzz。

## 2. 当前工程结构（Foundry）
```text
packages/auth-contract/
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
      MockPancakePairV2.sol
      MockWBNB.sol
      TestERC1967Proxy.sol
      TopicAccessManagerUpgradeableV2.sol
      ReentrantExecutorTarget.sol
      WadScaleHarness.sol
  script/
    Deploy.s.sol
    Upgrade.s.sol
    UpgradeAndMigrate.s.sol
  test/
    base/
      TestBase.sol
      TopicAccessFixture.sol
    unit/
      TopicAccessManager.Unit.t.sol
    security/
      TopicAccessManager.Guardrails.t.sol
      TopicAccessManager.Security.t.sol
    upgrade/
      TopicAccessManager.Upgrade.t.sol
    fuzz/
      TopicAccessManager.Fuzz.t.sol
  docs/
    README.md
    00-doc-layout.md
    01-requirements.md
    02-design.md
    03-implementation.md
    04-security-audit.md
    05-operations.md
    06-flowcharts.md
```

## 3. 分阶段实现
### Phase 1
- 合约骨架、初始化、UUPS 授权。

### Phase 2
- Topic + 白名单 + 鉴权。

### Phase 3
- 计费与报价（USDC/USDT/BNB/RAMBLE）。
- RAMBLE 充值走真实 V2 swap，按交易内实际收到 BNB 结算并应用折扣。

### Phase 4
- 风控与特权调用安全边界。

### Phase 5
- 升级回归与 fuzz。

## 4. WAD 与跨链实现要点
- `WAD` 仅内部记账单位，天然兼容多 EVM 链。
- 跨链迁移只需替换 RAMBLE 常量地址/默认 Pair 常量、oracle 与 delay 配置。
- 稳定币通过 `setStableToken` 动态注册，decimals 由链上自动读取并缓存，避免手工参数错误。

## 5. 需求-测试映射
- `AT-01` -> `unit/TopicAccessManager.Unit.t.sol`（topicKey hash）
- `AT-02` -> `unit/TopicAccessManager.Unit.t.sol`（free topic）
- `AT-03` -> `unit/TopicAccessManager.Unit.t.sol`（whitelist）
- `AT-04` -> `unit/TopicAccessManager.Unit.t.sol`（topup/expiry）
- `AT-05` -> `fuzz/TopicAccessManager.Fuzz.t.sol`（多精度）
- `AT-06` -> `fuzz/TopicAccessManager.Fuzz.t.sol`（rounding）
- `AT-07` -> `security/TopicAccessManager.Security.t.sol`（oracle 异常）
- `AT-08` -> `security/TopicAccessManager.Security.t.sol`（特权调用授权边界）
- `AT-09` -> `security/TopicAccessManager.Security.t.sol`（pause）
- `AT-10` -> `upgrade/TopicAccessManager.Upgrade.t.sol`（升级保状态）
- `AT-11` -> `security/TopicAccessManager.Security.t.sol`（owner 默认特权权限 + executor 后置配置）
- `AT-12` -> `security/TopicAccessManager.Guardrails.t.sol`（稳定币禁用后不可支付）
- `AT-13` -> `unit/TopicAccessManager.Unit.t.sol`（RAMBLE 常量地址与默认折扣）
- 额外 guardrails -> `security/TopicAccessManager.Guardrails.t.sol`（配置错误/异常路径）

## 6. 部署与升级（Foundry）
1. 部署：`forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast`
2. 升级：`forge script script/Upgrade.s.sol --rpc-url <RPC> --broadcast`
3. 升级并自动迁移旧稳定币（旧版推荐）：`forge script script/UpgradeAndMigrate.s.sol --rpc-url <RPC> --broadcast`
4. 部署后按需执行：
   - `setExecutors(executorA, executorB)`
   - `setStableToken(stableToken, true)`
   - `setRamblePair(rambleWbnbPair)`（若需覆盖默认常量）
5. 升级前检查：
   - `forge test --offline -vv`
   - 升级回归测试通过
   - storage 仅追加
6. 升级后检查：
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
- `forge test --offline --match-path test/fuzz/*.t.sol -vv`
- `forge coverage --offline --report summary`
- `npm run check:security`
- `forge script script/UpgradeAndMigrate.s.sol --rpc-url <RPC> --broadcast`
- `forge fmt`
- `forge clean`

## 9. 覆盖率快照
- 执行命令：`forge coverage --offline --report summary`
- 说明：`script/*.s.sol` 通常不计入单元测试覆盖，新增 `UpgradeAndMigrate.s.sol` 会拉低项目总体覆盖率，但不影响核心合约覆盖趋势。
- 核心合约 `src/TopicAccessManagerUpgradeable.sol`：
  - Lines: `89.26%` (291/326)
  - Statements: `90.64%` (310/342)
  - Branches: `66.18%` (45/68)
  - Funcs: `94.44%` (51/54)
- 项目总体：
  - Lines: `82.95%` (428/516)
  - Statements: `82.39%` (435/528)
  - Branches: `58.43%` (52/89)
  - Funcs: `90.53%` (86/95)

## 10. 流程图映射
- 鉴权流程：`./06-flowcharts.md` 第 2 节
- 充值主流程：`./06-flowcharts.md` 第 3 节
- RAMBLE 真实兑换：`./06-flowcharts.md` 第 4 节
- 升级迁移：`./06-flowcharts.md` 第 5 节

## 11. DoD
- `forge build` 通过。
- `forge test --offline` 全绿。
- 升级回归与安全检查覆盖完成。
- 文档全集（含 layout 与流程图）与代码一致。
