# BSC Topic 权限合约设计文档（v1.9）

关联文档：`../README.md`、`../governance/document-layout.md`、`../requirements/product-requirements.md`、`./storage-layout.md`、`./flowcharts.md`、`../implementation/implementation-guide.md`、`../operations/runbook.md`

## 1. 设计目标
- 把 `requirements/product-requirements.md` 的 `FR-* / NFR-*` 转化为可实现架构。
- 保持单合约最小化，并保证可升级与可审计。

## 2. 需求映射
- `FR-01/02/03/03A` -> Topic 管理与试用期模块。
- `FR-01A/01B` -> Topic registry 模块。
- `FR-04/05/05A` -> 鉴权、白名单与 topic 支付策略模块。
- `FR-06~12` -> 计费、报价、运营纠偏与结算保护模块。
- `FR-07~07D/21/22` -> payment token 配置与 oracle 风控模块。
- `FR-13` -> 特权调用模块。
- `FR-14/15` -> 暂停与升级治理模块。
- `FR-16` -> 事件模块。
- `NFR-02/03` -> 精度归一化与 rounding。
- `NFR-04/05` -> Oracle 与 Pair 风控。
- `NFR-06~09` -> 安全边界。

## 3. 架构设计
- 主合约：`TopicAccessManagerUpgradeable`。
- 内部拆分：继续保留单代理/单状态合约，但把纯策略和纯计算下沉到内部库，当前包含 `TopicAccessPolicyLib` 与 `RamblePricingLib`。
- 升级模式：`UUPS`。
- 代理实现：`ERC1967Proxy`。
- 依赖模块：
  - `Initializable`（`@openzeppelin/contracts/proxy/utils/`）
  - `UUPSUpgradeable`（`@openzeppelin/contracts/proxy/utils/`）
  - `Ownable2Step`（`@openzeppelin/contracts/access/`）
  - `Pausable`（`@openzeppelin/contracts/utils/`）
  - `ReentrancyGuard`（`@openzeppelin/contracts/utils/`）
  - `SafeERC20`
  - `Math`
- **永久约束 — OZ 非升级版合约**：
  本合约使用 `@openzeppelin/contracts/`（非 upgradeable）版本的 Ownable2Step、
  Pausable、ReentrancyGuard。在 OZ v5 中，非升级版与升级版使用不同的 ERC-7201
  命名空间 ID，存储布局不兼容。**未来升级绝不能切换到 `@openzeppelin/contracts-upgradeable/`**，
  否则会导致存储布局破坏。详见 `./storage-layout.md` 第 5 节。
- 初始化精简策略：
  - `initialize` 仅注入 `initialOwner + oracle + delay`。
  - RAMBLE 地址、默认 Pair、默认折扣使用合约常量，不通过初始化传参。
  - executor 地址通过 `setExecutors` 在部署后由 owner 单独配置。
  - payment token 通过 `setPaymentToken` / `setStableToken` 后置注册。
  - 试用期通过 `setGlobalTrialEndsAt` / `setTopicTrialEndsAt` 后置配置。
  - topic 级 payment allowlist 与人工订阅期纠偏通过 owner 后置配置。

## 4. WAD 规则与链约束
- `WAD=1e18` 是内部计费规则，不绑定具体链。
- 通用计费逻辑可复用于任意 EVM 链：BNB/native 路径、可配置 payment token、topic registry、试用期、鉴权规则都不依赖 BSC。
- RAMBLE 路径是例外：当前实现明确只在 `BSC chainId=56` 启用。
  - 非 BSC 链初始化时，不自动写入默认 RAMBLE Pair。
  - 非 BSC 链上 `quoteMinRambleForOneMonth`、`previewTopup(..., RAMBLE_TOKEN, ...)`、`topup(..., RAMBLE_TOKEN, ...)`、`setRamblePair` 全部 fail-fast。
  - 如果后续需要其他链支持 RAMBLE，应视为新的链级产品需求，而不是沿用当前常量直接复用。

## 5. Topic 与鉴权
- `topicId = keccak256(bytes(topicKey))`。
- 额外维护 `topicIds[] + topicKeyById`，便于链下管理后台按索引同步 topic 列表与可读 key。
- 额外维护 topic 级 payment allowlist；allowlist 未启用时保持历史默认路由，启用后按 `payToken` 精确准入。
- `hasAccess(topicId,user)` 判定顺序固定：
  1. topic 不存在 -> false
  2. 白名单 -> true
  3. 试用期有效 -> true
  4. `monthlyPriceWad==0` -> true
  5. `expiry>=block.timestamp` -> true
  6. else -> false

## 6. 计费模型
- `toWad(amount,decimals)` 统一归一化。
- 记账向下取整，报价向上取整。
- `secondsAdded = effectiveValueWad * 30 days / monthlyPriceWad`。
- `newExpiry = max(oldExpiry, now) + secondsAdded`。
- token decimals 在 `setPaymentToken/setStableToken` 时从链上读取并缓存，减少人工配置错误面。
- 虽然底层仍保留 upgrade-safe 的 legacy 并行 mapping，业务逻辑已经统一通过内部 `PaymentTokenConfig` 抽象访问，避免 payment token 读写继续散落在多个字段上。

### 6.1 币种路径
- 通用 payment token（动态注册）：
  - 若配置了 `usdOracle`：`rawValueWad = toWad(actualReceived, tokenDecimals) * tokenUsdPrice / 10^oracleDecimals`
  - 若未配置 `usdOracle`：按 1:1 USD 稳定币处理
  - 所有 ERC20 都按合约“实际到账数量”结算
- 在进入任何币种路径之前，先做 topic payment allowlist 检查；`address(0)` 表示原生 BNB。
- BNB：`rawValueWad = msg.value * bnbUsdPrice / 10^oracleDecimals`。
- RAMBLE：
  - 仅在 `BSC chainId=56` 激活；非 BSC 链直接回滚，避免错误暴露为“无流动性”或“pair 未配置”。
  - 报价阶段：基于 Pair 储备估算 `wbnbOut`，用于 `preview/quote`。
  - 充值阶段：真实执行 `RAMBLE -> WBNB` 的 V2 `swap`，再 `withdraw` 为 BNB。
  - `rawValueWad` 以交易内实际收到的 BNB 计价：
    - `rawValueWad = receivedBnbWei * bnbUsdPrice / 10^oracleDecimals`
    - `effectiveValueWad = rawValueWad * 10000 / rambleDiscountBps`
  - 若 `effectiveValueWad < monthlyPriceWad`，整笔回滚。

### 6.2 用户侧结算保护
- 推荐入口：`topup(..., minEffectiveValueWad, deadline)`。
- 若 `deadline != 0 && block.timestamp > deadline`，交易直接回滚。
- 若 `effectiveValueWad < minEffectiveValueWad`，交易回滚，避免预览到执行之间的滑点/到账偏差。

### 6.3 试用期策略
- 试用期分两层：
  - 全局试用期 `_globalTrialEndsAt`
  - 单个 topic 试用期 `_topicTrialEndsAt[topicId]`
- 生效规则：`effectiveTrialEndsAt = max(globalTrialEndsAt, topicTrialEndsAt[topicId])`。
- 业务效果：
  - `hasAccess == true`
  - `topup` 回滚，避免免费期仍误收款
  - `quoteMin* / previewTopup` 返回 `0`

### 6.4 运营纠偏
- `setExpiry(topicId, user, newExpiry)` 用于精确覆盖单个用户到期时间，适合迁移、补偿、人工修正。
- `extendExpiry(topicId, user, durationSeconds)` 用于按时长补偿；起算点为 `max(oldExpiry, block.timestamp)`，避免在已过期场景下把补偿加到历史时间之前。

## 7. 风控
- Chainlink：在 `setOracleConfig` 与运行期查询时都校验正值、时效、round 完整性，并验证地址有代码、接口可读。
- payment token oracle：在 `setPaymentToken(..., usdOracle)` 与运行期都复用同一组 Chainlink 有效性校验。
- Pair：配置时先校验包含 RAMBLE，且对手币必须支持 `withdraw(uint256)`；运行时继续校验储备非零、方向匹配、避免除零。
- Chain 保护：RAMBLE 所有入口先校验 `block.chainid == 56`，避免在非 BSC 链误开支付入口。
- Topic payment allowlist：作为 topic 级细粒度 kill switch；启用后 `topup/quote/preview` 共享同一准入规则。
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
- 完整槽位清单见：`./storage-layout.md`。
- 关键升级规则：
  - 只追加新状态变量。
  - 不重排、不删改类型、不改打包关系。
  - deprecated 字段必须保留，不能复用。

## 10. 推荐升级类型与步骤
### 10.1 推荐类型
- 推荐 `UUPS`：
  - 单合约模型匹配度高
  - 调用成本低
  - 授权点集中在 `_authorizeUpgrade`

### 10.2 升级步骤
1. 开发新实现（仅追加 storage）。
2. 执行 `forge test --offline`（含 upgrade/security/fuzz）。
3. 若有 `BSC_RPC_URL`，额外执行真实链上 fork 验证。
4. 部署新 implementation。
5. 通过 proxy 调用 `upgradeTo` / `upgradeToAndCall`。
6. 若从旧版迁移，执行升级迁移脚本自动注册 legacy 稳定币。
7. 校验关键状态与核心路径。

## 11. 与实现文档对照
- 工程结构：`../implementation/implementation-guide.md` 第 2 节。
- 测试矩阵：`../implementation/implementation-guide.md` 第 5 节。
- 部署升级：`../implementation/implementation-guide.md` 第 6 节。

## 12. 与流程图文档对照
- 鉴权状态机：`./flowcharts.md` 第 2 节。
- 充值主流程与分支：`./flowcharts.md` 第 3 节。
- RAMBLE 实际 swap 结算路径：`./flowcharts.md` 第 4 节。
- 升级与自动迁移：`./flowcharts.md` 第 5 节。

## 13. 与存储布局文档对照
- 当前槽位基线：`./storage-layout.md` 第 3 节。
- 升级约束与检查项：`./storage-layout.md` 第 4 节。
