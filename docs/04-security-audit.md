# BSC Topic 权限合约安全审计与加固记录（v1.2）

关联文档：`./01-requirements.md`、`./02-design.md`、`./06-flowcharts.md`、`./03-implementation.md`、`./05-operations.md`

## 1. 审计范围
- 主合约：`src/TopicAccessManagerUpgradeable.sol`
- 核心库：`src/libraries/WadScaleLib.sol`
- 关键测试：`test/security/*`、`test/upgrade/*`、`test/fuzz/*`

## 2. 审计方法
- 静态代码审阅：权限边界、资金路径、升级入口、配置一致性、价格路径。
- 动态测试：功能/安全/升级/fuzz 全量回归。
- 覆盖率检查：`forge coverage --offline --report summary`。

## 3. 审计结论
- 当前版本未发现会导致直接资金损失的高危缺陷。
- 已完成一轮安全加固，重点收敛了配置错误导致的风险敞口。
- 核心合约覆盖率达：Lines `89.26%`，Statements `90.64%`，Branches `66.18%`，Funcs `94.44%`。

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

### 4.2 残余风险（设计接受项）
1. 特权 `executePrivilegedCall` 本质是高权限后门能力，属于治理风险而非实现漏洞。  
   建议：owner 使用多签，executor 采用最小权限地址，并接入告警。

2. RAMBLE 估值依赖单一 Pair 的储备与预言机价格，存在流动性薄弱时的估值波动风险。  
   建议：运营侧设置 topic 月费下限、监控 Pair 储备变化，并保留快速暂停能力。

3. 升级权限集中于 owner。  
   建议：升级流程接入 timelock + 多签审批，执行前后固定跑 `check:security` 与升级回归。

## 5. 回归验证
- `forge test --offline -vv`：`48` passed, `0` failed
- `npm run check:security`：通过
- `forge coverage --offline --report summary`：通过
- `forge fmt --check`：通过
