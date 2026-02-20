# BSC Topic 权限合约设计文档（v1.8）

关联文档：`./README.md`、`./00-doc-layout.md`、`./01-requirements.md`、`./06-flowcharts.md`、`./03-implementation.md`、`./05-operations.md`

## 1. 设计目标
- 把 `01-requirements.md` 的 `FR-* / NFR-*` 转化为可实现架构。
- 保持单合约最小化，并保证可升级与可审计。

## 2. 需求映射
- `FR-01/02/03` -> Topic 管理模块。
- `FR-04/05` -> 鉴权与白名单模块。
- `FR-06~12` -> 计费与报价模块。
- `FR-13` -> 特权调用模块。
- `FR-14/15` -> 暂停与升级治理模块。
- `FR-16` -> 事件模块。
- `NFR-02/03` -> 精度归一化与 rounding。
- `NFR-04/05` -> Oracle 与 Pair 风控。
- `NFR-06~09` -> 安全边界。

## 3. 架构设计
- 主合约：`TopicAccessManagerUpgradeable`。
- 升级模式：`UUPS`。
- 代理实现：`ERC1967Proxy`。
- 依赖模块：
  - `Initializable`
  - `UUPSUpgradeable`
  - `Ownable2Step`
  - `Pausable`
  - `ReentrancyGuard`
  - `SafeERC20`
  - `Math`
- 初始化精简策略：
  - `initialize` 仅注入 `initialOwner + oracle + delay`。
  - RAMBLE 地址、默认 Pair、默认折扣使用合约常量，不通过初始化传参。
  - executor 地址通过 `setExecutors` 在部署后由 owner 单独配置。
  - 稳定币通过 `setStableToken` 后置注册。

## 4. WAD 规则与跨链兼容
- `WAD=1e18` 是内部计费规则，不绑定具体链。
- 任意 EVM 链可复用同一逻辑；仅需替换链级配置：
  - RAMBLE 常量地址与默认 Pair 常量（按目标链重编译）
  - 稳定币注册集合
  - oracle 地址
  - `maxOracleDelay`

## 5. Topic 与鉴权
- `topicId = keccak256(bytes(topicKey))`。
- `hasAccess(topicId,user)` 判定顺序固定：
  1. topic 不存在 -> false
  2. 白名单 -> true
  3. `monthlyPriceWad==0` -> true
  4. `expiry>=block.timestamp` -> true
  5. else -> false

## 6. 计费模型
- `toWad(amount,decimals)` 统一归一化。
- 记账向下取整，报价向上取整。
- `secondsAdded = effectiveValueWad * 30 days / monthlyPriceWad`。
- `newExpiry = max(oldExpiry, now) + secondsAdded`。
- token decimals 在 `setStableToken(token,true)` 时从链上读取并缓存，减少人工配置错误面。

### 6.1 币种路径
- 稳定币（动态注册）：`rawValueWad = toWad(amountIn, tokenDecimals)`。
- BNB：`rawValueWad = msg.value * bnbUsdPrice / 10^oracleDecimals`。
- RAMBLE：
  - 报价阶段：基于 Pair 储备估算 `wbnbOut`，用于 `preview/quote`。
  - 充值阶段：真实执行 `RAMBLE -> WBNB` 的 V2 `swap`，再 `withdraw` 为 BNB。
  - `rawValueWad` 以交易内实际收到的 BNB 计价：
    - `rawValueWad = receivedBnbWei * bnbUsdPrice / 10^oracleDecimals`
    - `effectiveValueWad = rawValueWad * 10000 / rambleDiscountBps`
  - 若 `effectiveValueWad < monthlyPriceWad`，整笔回滚。

## 7. 风控
- Chainlink：正值、时效、round 完整性。
- Pair：配置时先校验包含 RAMBLE，且对手币必须支持 `withdraw(uint256)`；运行时继续校验储备非零、方向匹配、避免除零。
- RAMBLE pair 地址若无代码，RAMBLE 路径显式失败，避免出现不透明 revert。
- 充值入口 `whenNotPaused`。
- `topup` / `executePrivilegedCall` 均 `nonReentrant`。
- 特权调用授权模型：`owner || executorA || executorB`。
- 初始化阶段不设置 executor，避免初始化参数膨胀；executor 后续由 owner 配置。
- 为升级迁移提供只读接口 `getLegacyStableTokens`，读取 deprecated 存储中的旧稳定币地址。

## 8. 事件最小化策略
- 事件只记录“无法稳定从链上当前状态回推”的关键事实。
- 不记录 operator/oldValue 等冗余字段，减少日志噪音与下游解析成本。
- `Topup` 保留支付主体、受益人、支付币种与输入、有效价值、新到期时间，满足审计与账务追踪。

## 9. 存储布局（V1）
1. `_topics`
2. `_expiryByTopicUser`
3. `_whitelistByTopicUser`
4. `_rambleDiscountBps`
5. `_executorA`
6. `_executorB`
7. `_usdc`（deprecated）
8. `_usdt`（deprecated）
9. `_ramble`（deprecated）
10. `_usdcDecimals`（deprecated）
11. `_usdtDecimals`（deprecated）
12. `_rambleDecimals`（deprecated）
13. `_bnbUsdOracle`
14. `_rambleWbnbPair`
15. `_maxOracleDelay`
16. `_stableTokenEnabled`
17. `_stableTokenDecimals`
18. `__gap`

升级规则：只追加，不重排，不删改类型。

## 10. 推荐升级类型与步骤
### 10.1 推荐类型
- 推荐 `UUPS`：
  - 单合约模型匹配度高
  - 调用成本低
  - 授权点集中在 `_authorizeUpgrade`

### 10.2 升级步骤
1. 开发新实现（仅追加 storage）。
2. 执行 `forge test --offline`（含 upgrade/security/fuzz）。
3. 部署新 implementation。
4. 通过 proxy 调用 `upgradeTo` / `upgradeToAndCall`。
5. 若从旧版迁移，执行升级迁移脚本自动注册 legacy 稳定币。
6. 校验关键状态与核心路径。

## 11. 与实现文档对照
- 工程结构：`./03-implementation.md` 第 2 节。
- 测试矩阵：`./03-implementation.md` 第 5 节。
- 部署升级：`./03-implementation.md` 第 6 节。

## 12. 与流程图文档对照
- 鉴权状态机：`./06-flowcharts.md` 第 2 节。
- 充值主流程与分支：`./06-flowcharts.md` 第 3 节。
- RAMBLE 实际 swap 结算路径：`./06-flowcharts.md` 第 4 节。
- 升级与自动迁移：`./06-flowcharts.md` 第 5 节。
