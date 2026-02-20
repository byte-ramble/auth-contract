# BSC Topic 权限合约需求文档（v1.9）

关联文档：`./README.md`、`./00-doc-layout.md`、`./02-design.md`、`./06-flowcharts.md`、`./03-implementation.md`、`./05-operations.md`

## 1. 目标与范围
- 在 BSC 实现可升级、最小化、安全优先的 Topic 权限合约。
- 支持付费订阅、白名单免收费、免费 Topic（`monthlyPriceWad=0`）。
- 支持 BNB / RAMBLE / 可配置稳定币充值。
- 支持任意常见 token decimals，通过归一化避免精度分叉。

## 2. 术语与规范
- `WAD`：内部统一计费单位，`1e18`。
- `topicKey`：人类可读字符串，例如 `omniarb.prod.alpha.vip.v1`。
- `topicId`：`keccak256(bytes(topicKey))`。
- `RAMBLE_TOKEN`（硬编码）：`0x1A8C391f6c603894108fcE14A52E9Bf804c67777`。
- `DEFAULT_RAMBLE_WBNB_PAIR`（硬编码默认值）：`0x185e706a55d04815e7e10b506A5a4d8d1153aeAD`。
- 命名规范：金额/价格字段统一 `...Wad` 后缀。

## 3. 角色与权限
- `owner`：
  - 管理 topic、价格、白名单、折扣、配置、暂停、升级、owner转移。
  - 默认具备特权 `call` 执行权限（无需额外配置）。
- `executorA` / `executorB`：
  - 由 owner 后置配置；配置后可执行特权 `call` 提取资产。

## 4. 功能需求（FR）
- `FR-01` 允许 owner 创建 topic（`createTopic` / `createTopicByKey`）。
- `FR-02` 允许 owner 修改 topic 月费，且仅影响未来充值。
- `FR-03` 支持 `monthlyPriceWad = 0`，表示免费 topic。
- `FR-04` 鉴权接口 `hasAccess(topicId,user)` 必须遵循优先级：
  - topic不存在 -> false
  - 白名单 -> true
  - 免费topic -> true
  - expiry有效 -> true
  - 其他 -> false
- `FR-05` 支持 topic 维度白名单管理：`setWhitelist`、`batchSetWhitelist`。
- `FR-06` 充值入口 `topup` 前置约束：
  - topic 必须存在
  - beneficiary 非零
  - 免费 topic 禁止充值
  - 白名单用户禁止充值
- `FR-07` 支持稳定币动态注册：owner 通过 `setStableToken(token, enabled)` 管理可支付稳定币。
- `FR-07A` 稳定币 decimals 由合约在启用时自动读取并校验，避免人工精度配置错误。
- `FR-08` 支持 BNB 充值，价格来自 Chainlink 实时事实查询。
- `FR-09` RAMBLE 采用合约内硬编码地址（BSC 主网），且充值必须走真实兑换路径：
  - 将 RAMBLE `transferFrom` 到合约
  - 合约把 RAMBLE 转入配置的 Pancake V2 Pair 并执行 `swap`
  - 将收到的 WBNB `withdraw` 成原生 BNB
  - 用“实际收到的 BNB”按 Chainlink 价格换算 `rawValueWad`
  - 按折扣系数计算 `effectiveValueWad`
- `FR-10` 最低充值：`effectiveValueWad >= monthlyPriceWad`。
- `FR-11` 到期时间计算：
  - `secondsAdded = effectiveValueWad * 30 days / monthlyPriceWad`
  - `newExpiry = max(oldExpiry, now) + secondsAdded`
- `FR-12` 提供报价与预览：`quoteMinBnbForOneMonth`、`quoteMinRambleForOneMonth`、`previewTopup`。
  - `quoteMinRambleForOneMonth` 为基于当前 Pair 储备的估算值。
  - RAMBLE 实际结算以 `topup` 交易内真实 swap 结果为准。
- `FR-13` 提供特权提取：`executePrivilegedCall`，owner 与 executorA/B 可调用。
- `FR-14` 提供 `pause/unpause`，暂停时拒绝充值。
- `FR-15` 提供 owner 两步转移与 UUPS 升级能力。
- `FR-16` 所有状态变更必须发事件日志，事件字段仅保留最小必要信息。
- `FR-17` 初始化仅传 `initialOwner`、`bnbUsdOracle`、`maxOracleDelay`，不传 executor 与 token 配置。
- `FR-18` RAMBLE 路径若真实 swap 后价值不足月费，必须整笔回滚，不得出现部分状态生效。
- `FR-19` RAMBLE 折扣与 Pair 具备默认值（常量），owner 可后续维护调整。
- `FR-20` 提供向后兼容迁移读取接口 `getLegacyStableTokens`，用于升级脚本自动迁移稳定币配置。

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
- `NFR-05` RAMBLE Pair 储备必须非零且方向正确。
- `NFR-05A` 设置 Pair 时必须前置校验 Pair 中包含 RAMBLE，避免运行期才暴露配置错误。
- `NFR-05B` 设置 Pair 时必须校验对手币支持 `withdraw(uint256)`，确保可解包为原生 BNB。
- `NFR-05C` RAMBLE Pair 未配置或地址无代码时，RAMBLE 路径必须明确失败，不得静默错误。
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
- `setTopicPrice(bytes32 topicId, uint256 newMonthlyPriceWad)`
- `setWhitelist(bytes32 topicId, address user, bool isWhitelisted)`
- `batchSetWhitelist(bytes32 topicId, address[] users, bool isWhitelisted)`
- `setRambleDiscountBps(uint16 newDiscountBps)`
- `setExecutors(address executorA, address executorB)`
- `setOracleConfig(address bnbUsdOracle, uint256 maxOracleDelay)`
- `setStableToken(address token, bool enabled)`
- `setRamblePair(address rambleWbnbPair)`
- `topup(bytes32 topicId, address payToken, uint256 amountIn, address beneficiary)`
- `executePrivilegedCall(address target, uint256 value, bytes data)`
- `pause()` / `unpause()`

### 6.2 读接口
- `getExpiry(bytes32 topicId, address user) -> uint256`
- `isWhitelisted(bytes32 topicId, address user) -> bool`
- `hasAccess(bytes32 topicId, address user) -> bool`
- `getTopicPriceWad(bytes32 topicId) -> uint256`
- `getRambleDiscountBps() -> uint16`
- `getStableTokenConfig(address token) -> (bool enabled, uint8 decimals)`
- `getLegacyStableTokens() -> (address legacyUsdc, address legacyUsdt)`
- `quoteMinBnbForOneMonth(bytes32 topicId) -> uint256`
- `quoteMinRambleForOneMonth(bytes32 topicId) -> uint256`
- `previewTopup(bytes32 topicId, address payToken, uint256 amountIn) -> (rawValueWad, effectiveValueWad, secondsAdded)`

## 7. 事件清单（最小必要字段）
- `TopicCreated(bytes32 topicId, uint256 monthlyPriceWad)`
- `TopicPriceUpdated(bytes32 topicId, uint256 newPriceWad)`
- `WhitelistUpdated(bytes32 topicId, address user, bool isWhitelisted)`
- `RambleDiscountUpdated(uint16 newBps)`
- `ExecutorsUpdated(address executorA, address executorB)`
- `OracleConfigUpdated(address oracle, uint256 maxOracleDelay)`
- `StableTokenUpdated(address token, bool enabled, uint8 decimals)`
- `RamblePairUpdated(address pair)`
- `Topup(bytes32 topicId, address payer, address beneficiary, address payToken, uint256 amountIn, uint256 effectiveValueWad, uint256 newExpiry)`
- `PrivilegedCallExecuted(address executor, address target, uint256 value, bool success)`
- `Paused(address account)` / `Unpaused(address account)`

## 8. 验收标准（AT）
- `AT-01` `topicKey` 与 `topicId` 哈希一致。
- `AT-02` 免费 topic：`hasAccess=true`、`topup` 失败、quote 返回 0。
- `AT-03` 白名单用户：`hasAccess=true`、`topup` 失败。
- `AT-04` 非白名单付费用户充值后 expiry 增加正确。
- `AT-05` 6/8/18/24 decimals token 归一化正确。
- `AT-06` 报价上取整、记账下取整。
- `AT-07` Chainlink 过期/异常时 BNB 与 RAMBLE 路径失败。
- `AT-08` 非授权地址（非 owner 且非 executor）不能执行特权调用。
- `AT-09` pause 后禁止充值，unpause 后恢复。
- `AT-10` 升级前后 topic/expiry/whitelist/discount 数据保持一致。
- `AT-11` 初始化后 owner 可直接执行特权调用，executor 默认为零地址。
- `AT-12` 稳定币未启用时不可支付；启用后可支付，禁用后再次不可支付。
- `AT-13` RAMBLE 地址为硬编码常量，不可通过初始化参数篡改。

## 9. 流程图映射
- 鉴权判定顺序：`06-flowcharts.md` 第 2 节
- `topup` 主流程：`06-flowcharts.md` 第 3 节
- RAMBLE 真实兑换结算：`06-flowcharts.md` 第 4 节
- 升级迁移流程：`06-flowcharts.md` 第 5 节
