# BSC Topic 权限合约运维周期测试文档（v1.1）

关联文档：`../README.md`、`../operations/runbook.md`、`../design/flowcharts.md`、`../implementation/implementation-guide.md`

## 1. 目标
- 说明“测试是否覆盖完整运维周期”的边界与结论。
- 把部署、配置、运行、应急、升级、迁移、回滚演练拆成可验证阶段。

## 2. 结论（当前版本）
- 可以覆盖完整运维周期的核心链路，方式为：
  - 自动化测试覆盖：核心业务与关键风控路径。
  - 运维 runbook 覆盖：脚本执行与链上核验步骤。
- 已增加真实 BSC fork 用例，覆盖真实 token/oracle 地址；但该部分仍依赖外部 RPC 与本机 Foundry 环境可用性。

## 3. 运维周期阶段与覆盖矩阵
| 阶段 | 目标 | 自动化覆盖 | 文档与脚本 |
| --- | --- | --- | --- |
| S1 部署 | 部署 proxy + implementation + initialize | `test/base/TopicAccessFixture.sol` 初始化流程 | `script/Deploy.s.sol`、`../operations/runbook.md` |
| S2 后置配置 | executors/payment token/trial/pair 配置生效 | `security/*.t.sol`、`unit/*.t.sol` | `../operations/runbook.md` |
| S3 业务运行 | createTopic / topup / hasAccess / quote | `unit/*.t.sol`、`fuzz/*.t.sol` | `../design/flowcharts.md` |
| S3A 真实链上校验 | BSC 主网 token/oracle 组合可工作 | `test/fork/TopicAccessManager.Fork.t.sol` | `../operations/runbook.md` |
| S4 应急处置 | pause/unpause 与权限边界 | `security/TopicAccessManager.Security.t.sol` | `../operations/runbook.md` |
| S5 升级 | UUPS upgrade + 状态保持 | `upgrade/TopicAccessManager.Upgrade.t.sol` | `script/Upgrade.s.sol` |
| S6 升级迁移 | legacy stable 自动迁移策略 | `test/lifecycle/TopicAccessManager.OpsLifecycle.t.sol` | `script/UpgradeAndMigrate.s.sol` |
| S7 回滚演练 | 升级失败后的回退流程 | 当前以 runbook + 手工演练为主 | `../operations/runbook.md` |

## 4. 建议执行顺序
1. 本地门禁：`npm run -w @omniarb/auth-contract test`
2. 生命周期专项：`npm run -w @omniarb/auth-contract test:lifecycle`
3. 安全门禁：`npm run -w @omniarb/auth-contract check:security`（已包含 `test:lifecycle`）
4. 若有 RPC：`BSC_RPC_URL=<RPC> npm run -w @omniarb/auth-contract test:fork`
5. 预发布演练：按 `../operations/runbook.md` 跑一遍部署与升级流程。

## 5. 覆盖边界说明
- 已覆盖（自动化）：
  - 鉴权顺序与免费/白名单边界。
  - 全局试用期与 topic 试用期边界。
  - BNB/稳定币/RAMBLE 充值及价值校验。
  - oracle 定价 payment token 的报价与充值。
  - 带 `minEffectiveValueWad + deadline` 的保护版充值。
  - fee-on-transfer 稳定币按实际到账数量结算。
  - pause/unpause、特权调用授权、重入防护。
  - 升级后状态保留与迁移路径可执行。
  - 真实 BSC token/oracle 地址的 fork 断言（环境允许时）。
- 未完全自动化（需运维演练）：
  - 真实主网 RPC 节点稳定性。
  - 极端行情下真实 AMM 滑点与链上拥堵影响。
  - 本机 Foundry/macOS 系统代理兼容性。
  - 多签审批延迟与组织流程执行质量。

## 6. 验收标准（运维测试）
- 生命周期关键阶段至少各有 1 个自动化断言或 runbook 检查点。
- 升级前后业务连续性必须通过：`hasAccess/topup/quote/privilegedCall`。
- 升级迁移后稳定币支付恢复可用（若 legacy token 有效）。
