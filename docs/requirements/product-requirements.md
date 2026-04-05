# BSC Topic 权限合约需求文档（v2.0）

关联文档：`../README.md`、`../governance/document-layout.md`、`../design/architecture.md`、`../design/flowcharts.md`、`../implementation/implementation-guide.md`、`../operations/runbook.md`

## 1. 目标与范围
- 在 BSC 实现可升级、最小化、安全优先的 Topic 权限合约。
- 支持付费订阅、白名单免收费、免费 Topic（`monthlyPriceWad=0`）。
- 支持 BNB / 仅限 BSC 的 RAMBLE / 可配置 ERC20 payment token 充值。
- 支持全局与单个 topic 维度免费试用期。
- 支持 topic 维度 payment allowlist，与单用户订阅期人工纠偏。
- 支持任意常见 token decimals，通过归一化避免精度分叉。

## 2. 术语与规范
- `WAD`：内部统一计费单位，`1e18`。
- `topicKey`：人类可读字符串，例如 `omniarb.prod.alpha.vip.v1`。
- `topicId`：`keccak256(bytes(topicKey))`。
- `BSC_CHAIN_ID`：`56`。
- `RAMBLE_TOKEN`（硬编码）：`0x1A8C391f6c603894108fcE14A52E9Bf804c67777`。
- `DEFAULT_RAMBLE_WBNB_PAIR`（硬编码默认值）：`0x185e706a55d04815e7e10b506A5a4d8d1153aeAD`。
- 命名规范：金额/价格字段统一 `...Wad` 后缀。
- BSC 主网样例 payment token / oracle：
  - `WETH`：`0x2170ed0880ac9a755fd29b2688956bd959f933f8` -> `ETH/USD`
  - `USDT`：`0x55d398326f99059ff775485246999027b3197955` -> `USDT/USD`
  - `USDC`：`0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d` -> `USDC/USD`
  - `WBNB`：`0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c` -> `BNB/USD`
  - `BTCB`：`0x7130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c` -> `BTC/USD`

## 3. 角色与权限
- `owner`：
  - 管理 topic、价格、白名单、折扣、配置、暂停、升级、owner转移。
  - 默认具备特权 `call` 执行权限（无需额外配置）。
- `executorA` / `executorB`：
  - 由 owner 后置配置；配置后可执行特权 `call` 提取资产。

## 4. 功能需求（FR）
- `FR-01` 允许 owner 创建 topic（`createTopic` / `createTopicByKey`）。
- `FR-01A` 提供 topic registry 读能力，支持按索引读取 topic 与已登记的 `topicKey`，便于链下后台同步。
- `FR-01B` 允许 owner 为已存在 topic 回填 `topicKey`（`setTopicKey`），且必须与 `topicId` 哈希一致。
- `FR-02` 允许 owner 修改 topic 月费，且仅影响未来充值。
- `FR-03` 支持 `monthlyPriceWad = 0`，表示免费 topic。
- `FR-03A` 允许 owner 配置全局试用期与单个 topic 试用期；试用期结束时间使用 unix timestamp 表示。
- `FR-04` 鉴权接口 `hasAccess(topicId,user)` 必须遵循优先级：
  - topic不存在 -> false
  - 白名单 -> true
  - 试用期有效 -> true
  - 免费topic -> true
  - expiry有效 -> true
  - 其他 -> false
- `FR-05` 支持 topic 维度白名单管理：`setWhitelist`、`batchSetWhitelist`。
- `FR-05A` 支持 topic 维度 payment allowlist：
  - `setTopicPaymentAllowlistEnabled(topicId, enabled)` 控制 topic 是否启用 allowlist
  - `setTopicPaymentToken(topicId, payToken, allowed)` 控制指定 `payToken` 是否允许
  - `payToken=address(0)` 表示原生 BNB
- `FR-06` 充值入口 `topup` 前置约束：
  - topic 必须存在
  - beneficiary 非零
  - 免费 topic 禁止充值
  - 试用期内禁止充值
  - 白名单用户禁止充值
- `FR-06B` 当 topic payment allowlist 已启用时，`topup/quote/preview` 都必须共享同一 payToken 准入规则；未允许的 payToken 必须显式失败。
- `FR-06A` 充值入口应提供用户侧结算保护参数：
  - `minEffectiveValueWad`：实际结算价值低于用户最小接受值时回滚
  - `deadline`：订单过期后拒绝执行
- `FR-07` 支持 payment token 动态注册：owner 通过 `setPaymentToken(token, enabled, usdOracle)` 管理可支付 ERC20。
- `FR-07A` payment token decimals 由合约在启用时自动读取并校验，避免人工精度配置错误。
- `FR-07B` ERC20 结算按合约“实际收到数量”计费，不按用户声明的 `amountIn` 盲记。
- `FR-07C` 支持无 oracle 的 1:1 USD 稳定币兼容入口 `setStableToken(token, enabled)`。
- `FR-07D` 带 oracle 的 payment token 在配置时必须同步校验 oracle 地址与当前数据有效性。
- `FR-08` 支持 BNB 充值，价格来自 Chainlink 实时事实查询。
- `FR-09` RAMBLE 采用合约内硬编码地址（BSC 主网），且仅在 `BSC chainId=56` 生效；非 BSC 链上 `quote/preview/topup/setRamblePair` 必须显式失败。BSC 上 RAMBLE 充值必须走真实兑换路径：
  - 将 RAMBLE `transferFrom` 到合约
  - 合约把 RAMBLE 转入配置的 Pancake V2 Pair 并执行 `swap`
  - 将收到的 WBNB `withdraw` 成原生 BNB
  - 用“实际收到的 BNB”按 Chainlink 价格换算 `rawValueWad`
  - 按折扣系数计算 `effectiveValueWad`
- `FR-10` 最低充值：`effectiveValueWad >= monthlyPriceWad`。
- `FR-11` 到期时间计算：
  - `secondsAdded = effectiveValueWad * 30 days / monthlyPriceWad`
  - `newExpiry = max(oldExpiry, now) + secondsAdded`
- `FR-11A` owner 可通过 `setExpiry(topicId, user, newExpiry)` 精确覆盖单个用户订阅到期时间。
- `FR-11B` owner 可通过 `extendExpiry(topicId, user, durationSeconds)` 为单个用户追加订阅期；起算点为 `max(oldExpiry, now)`。
- `FR-12` 提供报价与预览：`quoteMinBnbForOneMonth`、`quoteMinRambleForOneMonth`、`quoteMinTokenForOneMonth`、`previewTopup`。
  - `quoteMinRambleForOneMonth` 为基于当前 Pair 储备的估算值。
  - RAMBLE 实际结算以 `topup` 交易内真实 swap 结果为准。
  - 试用期或免费 topic 下，quote 与 preview 返回 `0`。
- `FR-13` 提供特权提取：`executePrivilegedCall`，owner 与 executorA/B 可调用。
- `FR-14` 提供 `pause/unpause`，暂停时拒绝充值。
- `FR-15` 提供 owner 两步转移与 UUPS 升级能力。
- `FR-16` 所有状态变更必须发事件日志，事件字段仅保留最小必要信息。
- `FR-17` 初始化仅传 `initialOwner`、`bnbUsdOracle`、`maxOracleDelay`，不传 executor 与 token 配置。
- `FR-18` RAMBLE 路径若真实 swap 后价值不足月费，必须整笔回滚，不得出现部分状态生效。
- `FR-19` RAMBLE 折扣与 Pair 具备默认值（常量），owner 可后续维护调整。
- `FR-20` 提供向后兼容迁移读取接口 `getLegacyStableTokens`，用于升级脚本自动迁移稳定币配置。
- `FR-21` `setOracleConfig` 时必须前置校验 oracle 地址有代码、接口可读且当前数据有效，避免误配延迟到运行期才暴露。
- `FR-22` 提供 `getPaymentTokenConfig/getGlobalTrialEndsAt/getTopicTrialEndsAt/getEffectiveTrialEndsAt/getTopicPaymentAllowlistEnabled/isTopicPaymentTokenAllowed` 等只读接口，便于后台同步与运维巡检。

## 5. 非功能需求（NFR）
- `NFR-01` 仅允许 `...Wad` 命名，不允许历史精度命名别名。
- `NFR-02` 记账向下取整，最低支付报价向上取整。
- `NFR-03` `toWad(amount,decimals)` 支持任意常见 decimals（建议限制 `<=36`）。
- `NFR-03A` token decimals 从链上读取后必须做上限校验（`<=36`），超限直接拒绝配置。
- `NFR-04` Chainlink 数据必须通过有效性检查：
  - `answer > 0`
  - `updatedAt > 0`
  - `block.timestamp - updatedAt <= maxOracleDelay`
  - `answeredInRound >= roundId`
- `NFR-04A` 带 oracle 的 payment token 在配置阶段与运行阶段都必须复用相同的 Chainlink 数据有效性检查。
- `NFR-05` RAMBLE Pair 储备必须非零且方向正确。
- `NFR-05A` 设置 Pair 时必须前置校验 Pair 中包含 RAMBLE，避免运行期才暴露配置错误。
- `NFR-05B` 设置 Pair 时必须校验对手币支持 `withdraw(uint256)`，确保可解包为原生 BNB。
- `NFR-05C` RAMBLE Pair 未配置或地址无代码时，RAMBLE 路径必须明确失败，不得静默错误。
- `NFR-05D` 非 `BSC chainId=56` 上 RAMBLE 路径必须 fail-fast；初始化时不得自动写入默认 RAMBLE Pair。
- `NFR-05E` topic payment allowlist 未启用时必须保持历史兼容行为；allowlist 启用后，`topup/quote/preview` 必须共享同一准入判断，不得出现接口间结果不一致。
- `NFR-06` `topup` 与 `executePrivilegedCall` 必须 `nonReentrant`。
- `NFR-07` ERC20 交互必须 `SafeERC20`。
- `NFR-08` 升级必须保持 storage layout 向后兼容，仅追加变量。
- `NFR-09` 特权调用禁止 `target==address(0)`、`target==address(this)`、禁止 delegatecall。
- `NFR-10` 事件设计遵循最小化原则：不重复记录可由链上状态推导的信息，不记录冗余旧值。

## 6. 接口清单
### 6.1 写接口
- `hashTopicKey(string topicKey) -> bytes32`
- `createTopic(bytes32 topicId, uint256 monthlyPriceWad)`
- `createTopicByKey(string topicKey, uint256 monthlyPriceWad)`
- `setTopicKey(bytes32 topicId, string topicKey)`
- `setTopicPrice(bytes32 topicId, uint256 newMonthlyPriceWad)`
- `setWhitelist(bytes32 topicId, address user, bool isWhitelisted)`
- `batchSetWhitelist(bytes32 topicId, address[] users, bool isWhitelisted)`
- `setRambleDiscountBps(uint16 newDiscountBps)`
- `setExecutors(address executorA, address executorB)`
- `setOracleConfig(address bnbUsdOracle, uint256 maxOracleDelay)`
- `setPaymentToken(address token, bool enabled, address usdOracle)`
- `setStableToken(address token, bool enabled)`
- `setRamblePair(address rambleWbnbPair)`
- `setGlobalTrialEndsAt(uint256 trialEndsAt)`
- `setTopicTrialEndsAt(bytes32 topicId, uint256 trialEndsAt)`
- `setTopicPaymentAllowlistEnabled(bytes32 topicId, bool enabled)`
- `setTopicPaymentToken(bytes32 topicId, address payToken, bool allowed)`
- `setExpiry(bytes32 topicId, address user, uint256 newExpiry)`
- `extendExpiry(bytes32 topicId, address user, uint256 durationSeconds) -> uint256`
- `topup(bytes32 topicId, address payToken, uint256 amountIn, address beneficiary)`
- `topup(bytes32 topicId, address payToken, uint256 amountIn, address beneficiary, uint256 minEffectiveValueWad, uint256 deadline)`
- `executePrivilegedCall(address target, uint256 value, bytes data)`
- `pause()` / `unpause()`

### 6.2 读接口
- `getExpiry(bytes32 topicId, address user) -> uint256`
- `isWhitelisted(bytes32 topicId, address user) -> bool`
- `hasAccess(bytes32 topicId, address user) -> bool`
- `getTopicCount() -> uint256`
- `getTopicAt(uint256 index) -> (bytes32 topicId, uint256 monthlyPriceWad, string topicKey)`
- `getTopicKey(bytes32 topicId) -> string`
- `getTopicPriceWad(bytes32 topicId) -> uint256`
- `getRambleDiscountBps() -> uint16`
- `getPaymentTokenConfig(address token) -> (bool enabled, uint8 tokenDecimals, address usdOracle, uint8 oracleDecimals)`
- `getStableTokenConfig(address token) -> (bool enabled, uint8 decimals)`
- `getLegacyStableTokens() -> (address legacyUsdc, address legacyUsdt)`
- `getGlobalTrialEndsAt() -> uint256`
- `getTopicTrialEndsAt(bytes32 topicId) -> uint256`
- `getEffectiveTrialEndsAt(bytes32 topicId) -> uint256`
- `getTopicPaymentAllowlistEnabled(bytes32 topicId) -> bool`
- `isTopicPaymentTokenAllowed(bytes32 topicId, address payToken) -> bool`
- `quoteMinBnbForOneMonth(bytes32 topicId) -> uint256`
- `quoteMinRambleForOneMonth(bytes32 topicId) -> uint256`
- `quoteMinTokenForOneMonth(bytes32 topicId, address payToken) -> uint256`
- `previewTopup(bytes32 topicId, address payToken, uint256 amountIn) -> (rawValueWad, effectiveValueWad, secondsAdded)`

## 7. 事件清单（最小必要字段）
- `TopicCreated(bytes32 topicId, uint256 monthlyPriceWad)`
- `TopicKeyRegistered(bytes32 topicId, string topicKey)`
- `TopicPriceUpdated(bytes32 topicId, uint256 newPriceWad)`
- `WhitelistUpdated(bytes32 topicId, address user, bool isWhitelisted)`
- `RambleDiscountUpdated(uint16 newBps)`
- `ExecutorsUpdated(address executorA, address executorB)`
- `OracleConfigUpdated(address oracle, uint256 maxOracleDelay)`
- `StableTokenUpdated(address token, bool enabled, uint8 decimals)`
- `PaymentTokenUpdated(address token, bool enabled, address usdOracle, uint8 tokenDecimals, uint8 oracleDecimals)`
- `GlobalTrialEndsAtUpdated(uint256 trialEndsAt)`
- `TopicTrialEndsAtUpdated(bytes32 topicId, uint256 trialEndsAt)`
- `TopicPaymentAllowlistUpdated(bytes32 topicId, bool enabled)`
- `TopicPaymentTokenUpdated(bytes32 topicId, address payToken, bool allowed)`
- `ExpiryUpdated(bytes32 topicId, address user, uint256 oldExpiry, uint256 newExpiry)`
- `RamblePairUpdated(address pair)`
- `Topup(bytes32 topicId, address payer, address beneficiary, address payToken, uint256 amountIn, uint256 effectiveValueWad, uint256 newExpiry)`
- `PrivilegedCallExecuted(address executor, address target, uint256 value, bool success)`
- `Paused(address account)` / `Unpaused(address account)`

## 8. 验收标准（AT）
- `AT-01` `topicKey` 与 `topicId` 哈希一致。
- `AT-02` 免费 topic：`hasAccess=true`、`topup` 失败、quote 返回 0。
- `AT-03` 白名单用户：`hasAccess=true`、`topup` 失败。
- `AT-03A` topic 试用期或全局试用期有效时：`hasAccess=true`、`topup` 失败、quote 返回 0。
- `AT-04` 非白名单付费用户充值后 expiry 增加正确。
- `AT-04A` 带 `minEffectiveValueWad` 的充值，在结算价值不足用户接受值时必须回滚。
- `AT-04B` 带 `deadline` 的充值，在超时后必须回滚。
- `AT-05` 6/8/18/24 decimals token 归一化正确。
- `AT-05A` fee-on-transfer 稳定币必须按实际到账数量结算。
- `AT-05B` 配置了 oracle 的 payment token，`quoteMinTokenForOneMonth` 与 `previewTopup` 必须基于 oracle 价格工作。
- `AT-05C` topic payment allowlist 启用后，未允许 payToken 的 `quote/preview/topup` 都必须显式失败；被允许的 payToken 保持可用。
- `AT-06` 报价上取整、记账下取整。
- `AT-07` Chainlink 过期/异常时 BNB 与 RAMBLE 路径失败。
- `AT-07A` 配置 payment token 时缺少/错误 oracle 必须在配置阶段失败。
- `AT-08` 非授权地址（非 owner 且非 executor）不能执行特权调用。
- `AT-09` pause 后禁止充值，unpause 后恢复。
- `AT-10` 升级前后 topic/expiry/whitelist/discount 数据保持一致。
- `AT-11` 初始化后 owner 可直接执行特权调用，executor 默认为零地址。
- `AT-11A` owner 可通过 `setExpiry/extendExpiry` 进行人工补偿或迁移纠偏；当旧 expiry 已经过期时，`extendExpiry` 必须从当前时间起算。
- `AT-12` 稳定币未启用时不可支付；启用后可支付，禁用后再次不可支付。
- `AT-13` RAMBLE 地址为硬编码常量，不可通过初始化参数篡改。
- `AT-13A` 非 BSC 链初始化时默认 RAMBLE Pair 保持未配置，且 RAMBLE 的 quote/preview/topup/setRamblePair 必须显式失败。
- `AT-14` `createTopicByKey` / `setTopicKey` 后，可通过 topic registry 读到 `topicId/price/topicKey`。
- `AT-15` 提供真实 BSC fork 用例，覆盖 `WETH/USDT/USDC/WBNB/BTCB` 的最小报价与试用期后支付恢复。

## 9. 流程图映射
- 鉴权判定顺序：`../design/flowcharts.md` 第 2 节
- `topup` 主流程：`../design/flowcharts.md` 第 3 节
- RAMBLE 真实兑换结算：`../design/flowcharts.md` 第 4 节
- 升级迁移流程：`../design/flowcharts.md` 第 5 节
