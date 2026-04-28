# TopicAccessManager 存储布局基线（v2.0）

关联文档：`./architecture.md`、`../operations/runbook.md`、`../security/security-audit.md`

## 1. 目的
- 提供升级前后可对照的 storage layout 基线。
- 明确继承自 OpenZeppelin 的状态槽位占用，避免手动估算出错。

## 2. 生成方式（可复现）
在 `packages/auth-contract` 下执行：

```bash
forge inspect src/TopicAccessManagerUpgradeable.sol:TopicAccessManagerUpgradeable storage-layout
```

如遇缓存异常：

```bash
forge clean
forge build --extra-output storageLayout
forge inspect src/TopicAccessManagerUpgradeable.sol:TopicAccessManagerUpgradeable storage-layout
```

## 3. 当前快照（2026-04-21）

> **OZ v5 存储模型说明**：
> `Initializable`（`_initialized` / `_initializing`）在 OZ v5 中改用 **ERC-7201 命名空间存储**，
> 不再占用顺序 slot；但当前实现使用的是 `@openzeppelin/contracts` 的非 upgradeable
> `ReentrancyGuard`，其 `_status` 仍然占用顺序 slot 2。

| Name | Type | Slot | Offset | Bytes |
| --- | --- | --- | --- | --- |
| `_owner` | `address` | 0 | 0 | 20 |
| `_pendingOwner` | `address` | 1 | 0 | 20 |
| `_paused` | `bool` | 1 | 20 | 1 |
| `_status` | `uint256` | 2 | 0 | 32 |
| `_topics` | `mapping(bytes32 => struct Topic)` | 3 | 0 | 32 |
| `_expiryByTopicUser` | `mapping(bytes32 => mapping(address => uint256))` | 4 | 0 | 32 |
| `_whitelistByTopicUser` | `mapping(bytes32 => mapping(address => bool))` | 5 | 0 | 32 |
| `_rambleDiscountBps` | `uint16` | 6 | 0 | 2 |
| `_executor` | `address` | 6 | 2 | 20 |
| `_usdc` (deprecated) | `address` | 7 | 0 | 20 |
| `_usdt` (deprecated) | `address` | 8 | 0 | 20 |
| `_ramble` (deprecated) | `address` | 9 | 0 | 20 |
| `_usdcDecimals` (deprecated) | `uint8` | 9 | 20 | 1 |
| `_usdtDecimals` (deprecated) | `uint8` | 9 | 21 | 1 |
| `_rambleDecimals` (deprecated) | `uint8` | 9 | 22 | 1 |
| `_bnbUsdOracle` | `address` | 10 | 0 | 20 |
| `_rambleWbnbPair` | `address` | 11 | 0 | 20 |
| `_maxOracleDelay` | `uint256` | 12 | 0 | 32 |
| `_paymentTokenEnabled` | `mapping(address => bool)` | 13 | 0 | 32 |
| `_paymentTokenDecimals` | `mapping(address => uint8)` | 14 | 0 | 32 |
| `_topicKeyById` | `mapping(bytes32 => string)` | 15 | 0 | 32 |
| `_topicIds` | `bytes32[]` | 16 | 0 | 32 |
| `_paymentTokenOracle` | `mapping(address => address)` | 17 | 0 | 32 |
| `_paymentTokenOracleDecimals` | `mapping(address => uint8)` | 18 | 0 | 32 |
| `_globalTrialEndsAt` | `uint256` | 19 | 0 | 32 |
| `_topicTrialEndsAt` | `mapping(bytes32 => uint256)` | 20 | 0 | 32 |
| `_topicPaymentAllowlistEnabled` | `mapping(bytes32 => bool)` | 21 | 0 | 32 |
| `_topicPaymentTokenAllowed` | `mapping(bytes32 => mapping(address => bool))` | 22 | 0 | 32 |
| `_topicDeactivated` | `mapping(bytes32 => bool)` | 23 | 0 | 32 |
| `__gap` | `uint256[30]` | 24 | 0 | 960 |

### 3.1 与 v1.2 快照差异摘要

| 变更 | 说明 |
| --- | --- |
| 移除 `_initialized`/`_initializing` (旧 slot 0) | OZ v5 `Initializable` 改用 ERC-7201 命名空间存储 |
| 保留 `_status` | 当前使用非 upgradeable `ReentrancyGuard`，`_status` 仍占顺序 slot 2 |
| `_executorA` → `_executor` | 统一为单 executor 语义，仍位于 slot 6 offset 2 |
| 删除保留的 legacy executor 槽位 | 首发前清理废弃执行器兼容字段，释放回 `__gap` |
| 重命名 `_stableTokenEnabled` → `_paymentTokenEnabled` | slot 14，功能扩展为通用 payment token |
| 重命名 `_stableTokenDecimals` → `_paymentTokenDecimals` | slot 15，同上 |
| 新增 `_topicDeactivated` | slot 23，支持 topic 停用/激活 |
| `__gap` 保持 `uint256[30]` | 首发前删除 legacy executor 槽位后，释放 1 个顺序 slot 回 `__gap` |

## 4. 升级约束
- 只能在末尾（`__gap` 之前）追加新状态变量，同时缩减 `__gap` 大小。
- 不能改已有变量类型、顺序、打包关系。
- deprecated 字段必须保留，不能删除或重排。
- 升级前后都执行：
  - `forge test --offline --match-path "test/upgrade/*.t.sol" -vv`
  - `forge test --offline --match-path "test/lifecycle/*.t.sol" -vv`

## 5. 永久约束：OZ 非升级版合约

> **重要**：本合约使用 `@openzeppelin/contracts/`（非 upgradeable 版本）的
> `Ownable2Step`、`Pausable`、`ReentrancyGuard`。在 OZ v5 中，这些合约的存储
> 布局与 `@openzeppelin/contracts-upgradeable/` 版本**不兼容**（后者使用不同的
> ERC-7201 命名空间 ID）。
>
> **未来升级绝不能切换到 OZ upgradeable 版本**，否则会导致存储布局完全破坏。
> 如需引入 OZ upgradeable 合约的新功能，必须手动移植逻辑而非替换 import。

## 6. 运维建议
- 每次准备升级实现时，先更新本文件快照并在 PR 中对比差异。
- 若出现 slot 漂移或 offset 变化，默认视为阻断级风险，停止发布。
