# TopicAccessManager 存储布局基线（v1.2）

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

## 3. 当前快照（2026-03-11）
| Name | Type | Slot | Offset | Bytes |
| --- | --- | --- | --- | --- |
| `_initialized` | `uint8` | 0 | 0 | 1 |
| `_initializing` | `bool` | 0 | 1 | 1 |
| `_owner` | `address` | 0 | 2 | 20 |
| `_pendingOwner` | `address` | 1 | 0 | 20 |
| `_paused` | `bool` | 1 | 20 | 1 |
| `_status` | `uint256` | 2 | 0 | 32 |
| `_topics` | `mapping(bytes32 => Topic)` | 3 | 0 | 32 |
| `_expiryByTopicUser` | `mapping(bytes32 => mapping(address => uint256))` | 4 | 0 | 32 |
| `_whitelistByTopicUser` | `mapping(bytes32 => mapping(address => bool))` | 5 | 0 | 32 |
| `_rambleDiscountBps` | `uint16` | 6 | 0 | 2 |
| `_executorA` | `address` | 6 | 2 | 20 |
| `_executorB` | `address` | 7 | 0 | 20 |
| `_usdc` (deprecated) | `address` | 8 | 0 | 20 |
| `_usdt` (deprecated) | `address` | 9 | 0 | 20 |
| `_ramble` (deprecated) | `address` | 10 | 0 | 20 |
| `_usdcDecimals` (deprecated) | `uint8` | 10 | 20 | 1 |
| `_usdtDecimals` (deprecated) | `uint8` | 10 | 21 | 1 |
| `_rambleDecimals` (deprecated) | `uint8` | 10 | 22 | 1 |
| `_bnbUsdOracle` | `address` | 11 | 0 | 20 |
| `_rambleWbnbPair` | `address` | 12 | 0 | 20 |
| `_maxOracleDelay` | `uint256` | 13 | 0 | 32 |
| `_stableTokenEnabled` | `mapping(address => bool)` | 14 | 0 | 32 |
| `_stableTokenDecimals` | `mapping(address => uint8)` | 15 | 0 | 32 |
| `_topicKeyById` | `mapping(bytes32 => string)` | 16 | 0 | 32 |
| `_topicIds` | `bytes32[]` | 17 | 0 | 32 |
| `_paymentTokenOracle` | `mapping(address => address)` | 18 | 0 | 32 |
| `_paymentTokenOracleDecimals` | `mapping(address => uint8)` | 19 | 0 | 32 |
| `_globalTrialEndsAt` | `uint256` | 20 | 0 | 32 |
| `_topicTrialEndsAt` | `mapping(bytes32 => uint256)` | 21 | 0 | 32 |
| `_topicPaymentAllowlistEnabled` | `mapping(bytes32 => bool)` | 22 | 0 | 32 |
| `_topicPaymentTokenAllowed` | `mapping(bytes32 => mapping(address => bool))` | 23 | 0 | 32 |
| `__gap` | `uint256[30]` | 24 | 0 | 960 |

## 4. 升级约束
- 只能在末尾追加新状态变量。
- 不能改已有变量类型、顺序、打包关系。
- deprecated 字段必须保留，不能删除或重排。
- 升级前后都执行：
  - `forge test --offline --match-path "test/upgrade/*.t.sol" -vv`
  - `forge test --offline --match-path "test/lifecycle/*.t.sol" -vv`

## 5. 运维建议
- 每次准备升级实现时，先更新本文件快照并在 PR 中对比差异。
- 若出现 slot 漂移或 offset 变化，默认视为阻断级风险，停止发布。
