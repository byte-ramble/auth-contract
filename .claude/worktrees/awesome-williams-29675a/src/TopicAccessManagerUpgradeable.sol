// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IAggregatorV3.sol";
import "./interfaces/IPancakePairV2.sol";
import "./libraries/RamblePricingLib.sol";
import "./libraries/TopicAccessPolicyLib.sol";
import "./libraries/WadScaleLib.sol";

/// @title TopicAccessManagerUpgradeable
/// @notice Manages paid access to named "topics": owner creates topics, users top up with native BNB,
///         RAMBLE, or an approved ERC20 payment token to extend their expiry, and whitelists / trial periods
///         grant free access without payment.
/// @dev Upgradeable via UUPS (`ERC1967Proxy`). Uses NON-upgradeable OZ v5 modules
///      (`Ownable2Step`, `Pausable`, `ReentrancyGuard`) by design — see `docs/design/storage-layout.md` §5;
///      switching to the OpenZeppelin `contracts-upgradeable` package would break storage layout and is
///      permanently forbidden.
/// @dev Storage layout is frozen: append only before `__gap` and shrink `__gap` accordingly. Legacy slots
///      `_usdc` / `_usdt` / `_ramble` / `_usd{c,t}Decimals` / `_rambleDecimals` are retained but unused;
///      runtime reads go through `_paymentTokenOracle` + `_paymentTokenDecimals`. Migration of the legacy
///      fields is handled by `script/UpgradeAndMigrate.s.sol`.
/// @dev The RAMBLE payment path is BSC-only (chainId 56). Non-BSC chains fail-fast on any RAMBLE quote /
///      preview / topup / pair configuration — see `_requireRamblePaymentSupported`.
/// @dev Requirement mapping: `FR-01..FR-16` / `NFR-01..NFR-09` — see `docs/requirements/product-requirements.md`.
/// @custom:security-contact See `docs/security/security-audit.md` for audit notes and known considerations
///      (oracle staleness, pair liquidity, reentrancy order, executor scope).
contract TopicAccessManagerUpgradeable is Initializable, UUPSUpgradeable, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Registered topic record.
    /// @dev `exists` is the sentinel that distinguishes a registered topic from the zero default —
    ///      a topic with `monthlyPriceWad == 0` is a free topic, not an unregistered one.
    struct Topic {
        /// @dev True once the topic has been created via `createTopic` / `createTopicByKey`.
        bool exists;
        /// @dev 30-day base price in WAD (USD-equivalent). Zero means the topic is fully free.
        uint256 monthlyPriceWad;
    }

    /// @notice In-memory view of an ERC20 payment token configuration (owner-registered).
    /// @dev The on-chain source of truth is the `_paymentToken*` mappings; this struct is the
    ///      aggregated read returned by `getPaymentTokenConfig` and consumed by internal quote helpers.
    struct PaymentTokenConfig {
        /// @dev True while the token is accepted by `topup`.
        bool enabled;
        /// @dev Cached ERC20 decimals read at `setPaymentToken` / `setStableToken` time.
        uint8 tokenDecimals;
        /// @dev Optional Chainlink-compatible USD oracle; `address(0)` means 1:1 stable handling (no oracle).
        address usdOracle;
        /// @dev Cached decimals of `usdOracle`, valid only when `usdOracle != address(0)`.
        uint8 oracleDecimals;
    }

    /// @notice Scratch record used inside `_topup` to carry the computed values into the receipt event.
    struct TopupCalc {
        /// @dev Post-discount effective value in WAD — the basis for the added time.
        uint256 effectiveValueWad;
        /// @dev Previous `(topic, user)` expiry timestamp (seconds).
        uint256 oldExpiry;
        /// @dev New expiry: `max(oldExpiry, now) + effectiveValueWad * 30d / monthlyPriceWad`.
        uint256 newExpiry;
    }

    /// @notice Internal accounting precision (1e18). All USD-equivalent values are expressed in WAD.
    /// @dev See `docs/design/architecture.md` §6 for the WAD billing model.
    uint256 public constant WAD = 1e18;
    /// @notice Basis-points denominator (`10_000 = 100%`).
    uint256 public constant BPS_BASE = 10_000;
    /// @notice Billing period length used when converting value-in-WAD into added seconds.
    uint256 public constant ONE_MONTH = 30 days;
    /// @notice Upper bound on `users.length` inside `batchSetWhitelist` to cap per-call gas.
    uint256 public constant MAX_BATCH_SIZE = 200;
    /// @notice BSC Mainnet chainId; gates the RAMBLE payment path (see `_isBscChain`).
    uint256 public constant BSC_CHAIN_ID = 56;

    /// @notice WBNB contract on BSC Mainnet.
    address public constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @notice RAMBLE ERC20 on BSC Mainnet.
    address public constant RAMBLE_TOKEN = 0x1A8C391f6c603894108fcE14A52E9Bf804c67777;
    /// @notice Default PancakeSwap V2 RAMBLE/WBNB pair, auto-bound when initializing on BSC.
    address public constant DEFAULT_RAMBLE_WBNB_PAIR = 0x185e706a55d04815e7e10b506A5a4d8d1153aeAD;
    /// @notice Default RAMBLE credit divisor (BPS). Credited value is `raw * BPS_BASE / bps`, so `9500` credits
    ///         `~100/95 ≈ 105.26%` of raw USD value — i.e. RAMBLE payers receive a ~5.26% premium over the spot
    ///         AMM quote. Lower BPS ⇒ bigger premium; `BPS_BASE` (10_000) means no premium (1:1 credit).
    uint16 public constant DEFAULT_RAMBLE_DISCOUNT_BPS = 9500;

    /// @dev PancakeSwap V2 amount-out numerator (0.25% taker fee ⇒ `9975 / 10_000`).
    uint256 private constant V2_FEE_NUMERATOR = 9975;
    /// @dev PancakeSwap V2 amount-out denominator (see `V2_FEE_NUMERATOR`).
    uint256 private constant V2_FEE_DENOMINATOR = 10_000;
    /// @dev Upper bound on the binary-search iterations inside `RamblePricingLib.quoteMinAmountForTargetValue`.
    uint256 private constant MAX_QUOTE_SEARCH_STEPS = 64;

    // ------------------------------------------------------------------ //
    //                         Topic / access state                       //
    // ------------------------------------------------------------------ //

    /// @dev `topicId => Topic`. `exists` remains true after `deactivateTopic`; use `_topicDeactivated` to gate writes.
    mapping(bytes32 => Topic) private _topics;
    /// @dev Per-user paid expiry timestamp in seconds; zero means never paid (non-whitelisted, non-trial users lack access).
    mapping(bytes32 => mapping(address => uint256)) private _expiryByTopicUser;
    /// @dev Free-access whitelist per topic; overrides payment entirely (`hasAccess == true`, `topup` rejects as non-needed).
    mapping(bytes32 => mapping(address => bool)) private _whitelistByTopicUser;

    /// @dev RAMBLE credit divisor in BPS — applied as `effectiveValueWad = rawValueWad * BPS_BASE / _rambleDiscountBps`.
    ///      Values below `BPS_BASE` credit MORE than the raw AMM-quoted USD value (premium for RAMBLE payers);
    ///      `BPS_BASE` is 1:1. Must satisfy `0 < bps <= BPS_BASE`. Set by `setRambleDiscountBps`.
    uint16 private _rambleDiscountBps;

    /// @dev Optional privileged caller authorized for `executePrivilegedCall` / `withdraw*`; `address(0)` disables it.
    address private _executor;

    // ------------------------------------------------------------------ //
    //  Deprecated legacy token config storage (retained for upgrade      //
    //  safety — NEVER delete or reorder these slots). Migration from     //
    //  these fields to the payment-token mappings is handled by          //
    //  `script/UpgradeAndMigrate.s.sol`.                                 //
    // ------------------------------------------------------------------ //

    address private _usdc;
    address private _usdt;
    address private _ramble;

    uint8 private _usdcDecimals;
    uint8 private _usdtDecimals;
    uint8 private _rambleDecimals;

    // ------------------------------------------------------------------ //
    //                     Oracle + RAMBLE pair config                    //
    // ------------------------------------------------------------------ //

    /// @dev Chainlink-compatible BNB/USD oracle used to price native BNB top-ups.
    address private _bnbUsdOracle;
    /// @dev PancakeSwap V2 RAMBLE/WBNB pair. Populated only on BSC; `address(0)` on non-BSC chains.
    address private _rambleWbnbPair;
    /// @dev Maximum tolerated oracle staleness (seconds); reads exceeding this revert with `OraclePriceStale`.
    uint256 private _maxOracleDelay;

    // ------------------------------------------------------------------ //
    //                      Payment-token registry                        //
    // ------------------------------------------------------------------ //

    /// @dev `token => enabled` — source of truth for whether a token can be used as payment.
    mapping(address => bool) private _paymentTokenEnabled;
    /// @dev Cached ERC20 decimals read at registration time (`setPaymentToken` / `setStableToken`).
    mapping(address => uint8) private _paymentTokenDecimals;

    // ------------------------------------------------------------------ //
    //                          Topic registry                            //
    // ------------------------------------------------------------------ //

    /// @dev Original human-readable `topicKey` for each `topicId`; lets off-chain admins recover the string.
    mapping(bytes32 => string) private _topicKeyById;
    /// @dev Append-only list of created `topicId`s (never pruned; `getTopicAt` supports paginated sync).
    bytes32[] private _topicIds;

    // ------------------------------------------------------------------ //
    //                   Payment-token USD oracle config                  //
    // ------------------------------------------------------------------ //

    /// @dev Optional USD oracle per payment token; `address(0)` = treat the token as a 1:1 USD stable.
    mapping(address => address) private _paymentTokenOracle;
    /// @dev Cached decimals of the per-token USD oracle (valid only when the oracle address is non-zero).
    mapping(address => uint8) private _paymentTokenOracleDecimals;

    // ------------------------------------------------------------------ //
    //                          Trial periods                             //
    // ------------------------------------------------------------------ //

    /// @dev Global trial cutoff timestamp in seconds; `0` disables the global trial (see `getGlobalTrialEndsAt`).
    uint256 private _globalTrialEndsAt;
    /// @dev Per-topic trial cutoff combined with `_globalTrialEndsAt` via `max(...)` in
    ///      `TopicAccessPolicyLib.effectiveTrialEndsAt`. Can only EXTEND the trial for a topic — never shorten
    ///      or disable the global trial for a single topic.
    mapping(bytes32 => uint256) private _topicTrialEndsAt;

    // ------------------------------------------------------------------ //
    //                Topic-level payment allowlist / status              //
    // ------------------------------------------------------------------ //

    /// @dev When true for a topic, only tokens explicitly marked in `_topicPaymentTokenAllowed` can top up it up;
    ///      when false, any globally-enabled token is accepted (legacy default route).
    mapping(bytes32 => bool) private _topicPaymentAllowlistEnabled;
    /// @dev Allowed payment tokens per topic when the allowlist is enabled. `address(0)` entry covers native BNB.
    mapping(bytes32 => mapping(address => bool)) private _topicPaymentTokenAllowed;

    /// @dev True once a topic has been paused via `deactivateTopic`; cleared by `reactivateTopic`.
    mapping(bytes32 => bool) private _topicDeactivated;

    /// @dev Reserved storage slots for future upgrades. Shrink this array when appending new state variables.
    uint256[30] private __gap;

    // ------------------------------------------------------------------ //
    //                          Custom errors                             //
    // ------------------------------------------------------------------ //

    /// @notice A required address parameter was the zero address.
    error ZeroAddress();
    /// @notice The supplied `topicKey` string was empty.
    error EmptyTopicKey();
    /// @notice The supplied `topicId` was the zero hash (likely derived from an empty key).
    error InvalidTopicId();
    /// @notice `topicId` has not been registered via `createTopic` / `createTopicByKey`.
    error TopicNotFound(bytes32 topicId);
    /// @notice A record for this `topicId` already exists — choose a different `topicKey`.
    error TopicAlreadyExists(bytes32 topicId);
    /// @notice A required amount / quantity parameter was zero.
    error AmountZero();
    /// @notice The given `payToken` is not enabled as a payment token.
    error UnsupportedPayToken(address payToken);
    /// @notice `msg.value` did not match the declared native `amountIn` for a BNB top-up.
    error NativeValueMismatch(uint256 msgValue, uint256 amountIn);
    /// @notice Native value was attached to a non-native top-up — resubmit with `msg.value == 0`.
    error UnexpectedNativeValue(uint256 msgValue);
    /// @notice The payment `deadline` has passed — caller should resubmit with a fresh deadline.
    error PaymentDeadlineExpired(uint256 deadline, uint256 nowTimestamp);
    /// @notice Topic is free (`monthlyPriceWad == 0`); top-ups are rejected so funds cannot be misrouted.
    error FreeTopicNoPaymentRequired(bytes32 topicId);
    /// @notice Trial period is active for this topic; top-ups are rejected until `trialEndsAt`.
    error TrialPeriodNoPaymentRequired(bytes32 topicId, uint256 trialEndsAt);
    /// @notice Beneficiary is whitelisted; top-ups are rejected because access is already free.
    error WhitelistedUserNoPaymentRequired(bytes32 topicId, address user);
    /// @notice Computed effective value is below one full month of price — top-ups must buy a whole month.
    error MinimumPaymentNotMet(uint256 effectiveValueWad, uint256 monthlyPriceWad);
    /// @notice Computed effective value is below the caller-supplied slippage floor `minEffectiveValueWad`.
    error EffectiveValueBelowMinimum(uint256 effectiveValueWad, uint256 minEffectiveValueWad);
    /// @notice RAMBLE discount BPS must satisfy `0 < bps <= BPS_BASE`.
    error InvalidDiscountBps(uint16 discountBps);
    /// @notice `setOracleConfig` called with `oracle == 0` or `maxOracleDelay == 0`.
    error InvalidOracleConfig();
    /// @notice Oracle failed interface or sanity checks at configuration time.
    error InvalidOracle(address oracle);
    /// @notice Payment token configuration demanded a USD oracle but `address(0)` was supplied.
    error PaymentTokenOracleRequired(address token);
    /// @notice The token is not in this topic's payment allowlist.
    error PayTokenNotAllowedForTopic(bytes32 topicId, address payToken);
    /// @notice RAMBLE payment path invoked on a non-BSC chain — path is BSC-only.
    error RambleOnlySupportedOnBsc(uint256 chainId);
    /// @notice Caller is neither owner nor the configured `_executor`.
    error NotExecutor(address caller);
    /// @notice `executePrivilegedCall` targeted `address(0)` or `address(this)`. Note: payment-token and
    ///         RAMBLE-pair addresses are NOT blocked here; only the `IERC20.transfer` selector is rejected
    ///         separately (via `UseWithdrawERC20`).
    error InvalidPrivilegedTarget(address target);
    /// @notice `setStableToken` called on a disallowed token (e.g. native wrapper or the RAMBLE token).
    error InvalidStableToken(address token);
    /// @notice A required duration parameter was zero.
    error DurationZero();
    /// @notice Oracle returned a non-positive price.
    error OraclePriceInvalid();
    /// @notice Oracle last-update timestamp is older than `maxOracleDelay`.
    error OraclePriceStale(uint256 updatedAt, uint256 nowTimestamp, uint256 maxOracleDelay);
    /// @notice Oracle returned a round that has not yet settled (`answeredInRound < roundId`).
    error OracleRoundInvalid(uint80 roundId, uint80 answeredInRound);
    /// @notice Supplied `topicKey` does not hash to the supplied `topicId` — caller mixed up the pair.
    error TopicKeyMismatch(bytes32 topicId, bytes32 derivedTopicId);
    /// @notice `getTopicAt(index)` was called with an out-of-range index.
    error TopicIndexOutOfBounds(uint256 index, uint256 count);
    /// @notice The configured pair does not contain the expected RAMBLE token in either slot.
    error PairTokenMismatch(address token0, address token1, address ramble);
    /// @notice The configured pair's non-RAMBLE leg is not the expected `wrappedNative` address.
    error InvalidWrappedNative(address wrappedNative, address expectedWrappedNative);
    /// @notice The RAMBLE pair has not been configured (`address(0)`).
    error RamblePairNotConfigured(address pair);
    /// @notice The configured RAMBLE pair has insufficient reserves to safely quote / swap.
    error PairLiquidityTooLow();
    /// @notice WBNB `withdraw()` returned without transferring the expected amount of native.
    error WrappedNativeWithdrawFailed(address wrappedNative);
    /// @notice Unable to produce a quote (e.g. binary search exhausted, pair state degraded).
    error QuoteUnavailable();
    /// @notice RAMBLE top-ups require a non-zero `minEffectiveValueWad` (mandatory slippage guard).
    error RambleSlippageProtectionRequired();
    /// @notice Topic has been deactivated via `deactivateTopic` and cannot accept top-ups.
    error TopicIsDeactivated(bytes32 topicId);
    /// @notice Topic is already active; `reactivateTopic` has nothing to do.
    error TopicAlreadyActive(bytes32 topicId);
    /// @notice `batchSetWhitelist` called with more addresses than `MAX_BATCH_SIZE`.
    error BatchSizeExceeded(uint256 provided, uint256 max);
    /// @notice Native transfer to `recipient` failed during `withdrawNative` / privileged withdrawal.
    error NativeWithdrawalFailed(address recipient);
    /// @notice Caller used `withdrawNative` for an ERC20 asset; use `withdrawERC20` instead.
    error UseWithdrawERC20(address token);

    // ------------------------------------------------------------------ //
    //                              Events                                //
    // ------------------------------------------------------------------ //

    /// @notice Emitted once when a topic is first created, carrying its base monthly price in WAD.
    event TopicCreated(bytes32 indexed topicId, uint256 monthlyPriceWad);
    /// @notice Emitted when the human-readable `topicKey` is registered or updated for a `topicId`.
    event TopicKeyRegistered(bytes32 indexed topicId, string topicKey);
    /// @notice Emitted when a topic's monthly price is updated.
    event TopicPriceUpdated(bytes32 indexed topicId, uint256 newPriceWad);
    /// @notice Emitted when a user's whitelist status on a topic changes.
    event WhitelistUpdated(bytes32 indexed topicId, address indexed user, bool isWhitelisted);

    /// @notice Emitted when the RAMBLE credit discount BPS is updated.
    event RambleDiscountUpdated(uint16 newBps);

    /// @notice Emitted when the privileged executor address is set or cleared (`executor == address(0)`).
    event ExecutorUpdated(address indexed executor);

    /// @notice Emitted when the BNB/USD oracle or its `maxOracleDelay` is updated.
    event OracleConfigUpdated(address indexed oracle, uint256 maxOracleDelay);

    /// @notice Emitted for legacy 1:1 USD stable configuration via `setStableToken` (kept for backward compatibility).
    event StableTokenUpdated(address indexed token, bool enabled, uint8 decimals);
    /// @notice Emitted when a payment token's registration is added, updated, or disabled.
    /// @dev `usdOracle == address(0)` denotes a 1:1 stable route; otherwise the oracle is used to price the token.
    event PaymentTokenUpdated(
        address indexed token, bool enabled, address indexed usdOracle, uint8 tokenDecimals, uint8 oracleDecimals
    );
    /// @notice Emitted when the global trial cutoff timestamp is updated.
    event GlobalTrialEndsAtUpdated(uint256 trialEndsAt);
    /// @notice Emitted when a topic-specific trial cutoff is updated; effective cutoff is `max(global, topic)`.
    event TopicTrialEndsAtUpdated(bytes32 indexed topicId, uint256 trialEndsAt);
    /// @notice Emitted when a topic's payment allowlist is enabled or disabled.
    event TopicPaymentAllowlistUpdated(bytes32 indexed topicId, bool enabled);
    /// @notice Emitted when a specific `payToken` is added to or removed from a topic's allowlist.
    /// @dev `payToken == address(0)` covers the native-BNB entry.
    event TopicPaymentTokenUpdated(bytes32 indexed topicId, address indexed payToken, bool allowed);
    /// @notice Emitted whenever a (topic, user) expiry changes — via `topup`, `setExpiry`, or `extendExpiry`.
    event ExpiryUpdated(bytes32 indexed topicId, address indexed user, uint256 oldExpiry, uint256 newExpiry);

    /// @notice Emitted when the RAMBLE/WBNB PancakeSwap V2 pair is configured.
    event RamblePairUpdated(address indexed pair);

    /// @notice Emitted on a successful `topup`, carrying the caller-declared amount, post-discount WAD value, and new expiry.
    /// @param topicId Topic paid for.
    /// @param payer The account that supplied funds / approved the token (`msg.sender`).
    /// @param beneficiary The account whose expiry was extended.
    /// @param payToken Token used to pay (`address(0)` for native BNB).
    /// @param amountIn The `amountIn` argument passed to `topup` (request/approval amount).
    ///        For native BNB this equals `msg.value`. For fee-on-transfer ERC20s and the RAMBLE path the
    ///        amount actually received by the contract / pair may be lower; crediting always uses that
    ///        measured amount internally, but this event field is the requested amount, not net received.
    /// @param effectiveValueWad Post-discount value-in-WAD credited toward the new expiry (derived from the net received amount).
    /// @param newExpiry Resulting expiry timestamp for `(topicId, beneficiary)`.
    event Topup(
        bytes32 indexed topicId,
        address indexed payer,
        address indexed beneficiary,
        address payToken,
        uint256 amountIn,
        uint256 effectiveValueWad,
        uint256 newExpiry
    );

    /// @notice Emitted when `executePrivilegedCall` returns; `success` reflects the low-level call outcome.
    event PrivilegedCallExecuted(address indexed executor, address indexed target, uint256 value, bool success);
    /// @notice Emitted when `withdrawNative` / `withdrawERC20` ships funds to `recipient`.
    event PrivilegedWithdrawalExecuted(
        address indexed executor, address indexed asset, address indexed recipient, uint256 amount
    );

    /// @notice Emitted when `deactivateTopic` pauses further top-ups for a topic.
    event TopicDeactivated(bytes32 indexed topicId);
    /// @notice Emitted when `reactivateTopic` re-enables a previously deactivated topic.
    event TopicReactivated(bytes32 indexed topicId);

    /// @notice Deployer-only constructor; the implementation is never used directly.
    /// @dev Disables initializers on the implementation contract so it cannot be re-initialised through
    ///      the `ERC1967Proxy` pattern. State is actually configured in `initialize`.
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    // ------------------------------------------------------------------ //
    //                        Initialization / upgrade                    //
    // ------------------------------------------------------------------ //

    /// @notice One-time initializer called immediately after `ERC1967Proxy` deployment.
    /// @dev Sets the BNB/USD oracle + staleness bound, applies the default RAMBLE discount, auto-binds the
    ///      default RAMBLE/WBNB pair on BSC, and transfers ownership to `initialOwner`. Covers FR-15 / NFR-04.
    /// @param initialOwner Initial owner (`Ownable2Step`); must not be `address(0)`.
    /// @param bnbUsdOracle_ Chainlink-compatible BNB/USD oracle; subject to interface + liveness probe.
    /// @param maxOracleDelay_ Maximum accepted oracle staleness (seconds); must be non-zero.
    function initialize(
        address initialOwner,
        address bnbUsdOracle_,
        uint256 maxOracleDelay_
    ) external initializer {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }

        _setOracleConfig(bnbUsdOracle_, maxOracleDelay_);
        _setRambleDiscountBps(DEFAULT_RAMBLE_DISCOUNT_BPS);
        _setDefaultRamblePair();

        _transferOwnership(initialOwner);
    }

    /// @notice Accepts native BNB — required because `_swapRambleToBnb` pulls BNB out of WBNB into this contract.
    receive() external payable { }

    // ------------------------------------------------------------------ //
    //                           Topic management                         //
    // ------------------------------------------------------------------ //

    /// @notice Convenience helper to compute `topicId = keccak256(bytes(topicKey))` off-chain.
    /// @param topicKey The human-readable topic key.
    /// @return The `topicId` derived from `topicKey`.
    function hashTopicKey(
        string calldata topicKey
    ) external pure returns (bytes32) {
        return _hashTopicKey(topicKey);
    }

    /// @notice Registers a new topic by its pre-computed `topicId`.
    /// @dev Fails if a topic with that id already exists. Covers FR-01.
    /// @param topicId Unique id (typically `keccak256(bytes(topicKey))`).
    /// @param monthlyPriceWad Base 30-day price in WAD; `0` makes the topic permanently free.
    function createTopic(
        bytes32 topicId,
        uint256 monthlyPriceWad
    ) external onlyOwner {
        _createTopic(topicId, monthlyPriceWad);
    }

    /// @notice Registers a new topic using its human-readable key (derives `topicId` internally) and records the key.
    /// @dev Emits both `TopicCreated` and `TopicKeyRegistered`. Covers FR-01 / FR-01A.
    /// @param topicKey The human-readable key; must be non-empty.
    /// @param monthlyPriceWad Base 30-day price in WAD.
    function createTopicByKey(
        string calldata topicKey,
        uint256 monthlyPriceWad
    ) external onlyOwner {
        bytes32 topicId = _hashTopicKey(topicKey);
        _createTopic(topicId, monthlyPriceWad);
        _registerTopicKey(topicId, topicKey);
    }

    /// @notice Registers or updates the human-readable `topicKey` for an existing `topicId`.
    /// @dev Reverts if `topicKey` does not hash to `topicId` — callers must supply a matching pair. Covers FR-01B.
    function setTopicKey(
        bytes32 topicId,
        string calldata topicKey
    ) external onlyOwner {
        _requireTopic(topicId);
        _registerTopicKey(topicId, topicKey);
    }

    /// @notice Updates a topic's monthly price (WAD).
    /// @dev Applies only to future top-ups; does not rewrite already-purchased expirations. Covers FR-03.
    function setTopicPrice(
        bytes32 topicId,
        uint256 newMonthlyPriceWad
    ) external onlyOwner {
        Topic storage topic = _requireTopic(topicId);
        topic.monthlyPriceWad = newMonthlyPriceWad;

        emit TopicPriceUpdated(topicId, newMonthlyPriceWad);
    }

    /// @notice Deactivates a topic; further top-ups are rejected and `isTopicActive` becomes `false`.
    /// @dev Existing expirations remain valid; `hasAccess` still honours paid users. Covers FR-03A.
    function deactivateTopic(
        bytes32 topicId
    ) external onlyOwner {
        _requireTopic(topicId);
        if (_topicDeactivated[topicId]) {
            revert TopicIsDeactivated(topicId);
        }
        _topicDeactivated[topicId] = true;
        emit TopicDeactivated(topicId);
    }

    /// @notice Re-enables a previously deactivated topic.
    function reactivateTopic(
        bytes32 topicId
    ) external onlyOwner {
        _requireTopic(topicId);
        if (!_topicDeactivated[topicId]) {
            revert TopicAlreadyActive(topicId);
        }
        _topicDeactivated[topicId] = false;
        emit TopicReactivated(topicId);
    }

    /// @notice Returns `true` iff the topic exists AND has not been deactivated.
    function isTopicActive(
        bytes32 topicId
    ) external view returns (bool) {
        return _topics[topicId].exists && !_topicDeactivated[topicId];
    }

    // ------------------------------------------------------------------ //
    //                       Whitelist / expiry                           //
    // ------------------------------------------------------------------ //

    /// @notice Grants or revokes free access for a single user on a topic.
    /// @dev Whitelisted users always have access and cannot be charged via `topup`. Covers FR-04.
    function setWhitelist(
        bytes32 topicId,
        address user,
        bool isWhitelisted_
    ) external onlyOwner {
        _requireTopic(topicId);
        if (user == address(0)) {
            revert ZeroAddress();
        }

        _whitelistByTopicUser[topicId][user] = isWhitelisted_;

        emit WhitelistUpdated(topicId, user, isWhitelisted_);
    }

    /// @notice Grants or revokes free access for a batch of users on a topic.
    /// @dev Batch capped by `MAX_BATCH_SIZE`. Emits one `WhitelistUpdated` per address. Covers FR-04.
    /// @param topicId Topic to affect.
    /// @param users Addresses to update; each must be non-zero.
    /// @param isWhitelisted_ True to grant, false to revoke.
    function batchSetWhitelist(
        bytes32 topicId,
        address[] calldata users,
        bool isWhitelisted_
    ) external onlyOwner {
        _requireTopic(topicId);
        if (users.length > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded(users.length, MAX_BATCH_SIZE);
        }

        uint256 len = users.length;
        for (uint256 i = 0; i < len; ++i) {
            address user = users[i];
            if (user == address(0)) {
                revert ZeroAddress();
            }

            _whitelistByTopicUser[topicId][user] = isWhitelisted_;
            emit WhitelistUpdated(topicId, user, isWhitelisted_);
        }
    }

    // ------------------------------------------------------------------ //
    //                    Global + per-topic configuration                //
    // ------------------------------------------------------------------ //

    /// @notice Updates the RAMBLE credit discount (BPS). Must be `0 < bps <= BPS_BASE`.
    function setRambleDiscountBps(
        uint16 newDiscountBps
    ) external onlyOwner {
        _setRambleDiscountBps(newDiscountBps);
    }

    /// @notice Sets or clears the privileged executor. `address(0)` disables `executePrivilegedCall` for non-owners.
    /// @dev Covers FR-13. Executor can still be bypassed by the owner at any time.
    function setExecutor(
        address executor_
    ) external onlyOwner {
        _setExecutor(executor_);
    }

    /// @notice Updates the BNB/USD oracle and its acceptable staleness.
    /// @dev Runs an interface + liveness probe before accepting. Covers NFR-04.
    function setOracleConfig(
        address bnbUsdOracle_,
        uint256 maxOracleDelay_
    ) external onlyOwner {
        _setOracleConfig(bnbUsdOracle_, maxOracleDelay_);
    }

    /// @notice Enables / disables a token as a 1:1 USD stable (no oracle).
    /// @dev Legacy entry kept for backward compatibility; prefer `setPaymentToken` when an oracle is available.
    ///      Reverts on disallowed tokens (native wrapper, RAMBLE). Covers FR-07.
    function setStableToken(
        address token,
        bool enabled
    ) external onlyOwner {
        (uint8 tokenDecimals,) = _setPaymentToken(token, enabled, address(0), false);
        emit StableTokenUpdated(token, enabled, tokenDecimals);
    }

    /// @notice Enables / disables a token as a payment token with an optional USD oracle.
    /// @dev `usdOracle == address(0)` falls back to 1:1 stable treatment. Caches decimals at registration.
    ///      Covers FR-07 / FR-07A..D / NFR-04.
    function setPaymentToken(
        address token,
        bool enabled,
        address usdOracle
    ) external onlyOwner {
        _setPaymentToken(token, enabled, usdOracle, true);
    }

    /// @notice Configures the PancakeSwap V2 RAMBLE/WBNB pair. BSC-only.
    /// @dev Validates tokens + liquidity before accepting. Reverts `RambleOnlySupportedOnBsc` on other chains.
    function setRamblePair(
        address rambleWbnbPair_
    ) external onlyOwner {
        _setRamblePair(rambleWbnbPair_);
    }

    /// @notice Sets the global trial cutoff timestamp (seconds). `0` disables the global trial.
    /// @dev Covers FR-21.
    function setGlobalTrialEndsAt(
        uint256 trialEndsAt
    ) external onlyOwner {
        _globalTrialEndsAt = trialEndsAt;
        emit GlobalTrialEndsAtUpdated(trialEndsAt);
    }

    /// @notice Sets a topic-level trial cutoff that EXTENDS (but cannot shorten) the global cutoff for that topic.
    /// @dev Effective cutoff is `max(_globalTrialEndsAt, _topicTrialEndsAt[topicId])`. Setting a value below
    ///      the global cutoff is a no-op for `hasAccess`; clearing (`0`) reverts the topic to the global cutoff.
    ///      Covers FR-21.
    function setTopicTrialEndsAt(
        bytes32 topicId,
        uint256 trialEndsAt
    ) external onlyOwner {
        _requireTopic(topicId);
        _topicTrialEndsAt[topicId] = trialEndsAt;
        emit TopicTrialEndsAtUpdated(topicId, trialEndsAt);
    }

    /// @notice Toggles the per-topic payment allowlist. When enabled, only explicitly allowed tokens may pay.
    /// @dev Covers FR-22.
    function setTopicPaymentAllowlistEnabled(
        bytes32 topicId,
        bool enabled
    ) external onlyOwner {
        _requireTopic(topicId);
        _topicPaymentAllowlistEnabled[topicId] = enabled;
        emit TopicPaymentAllowlistUpdated(topicId, enabled);
    }

    /// @notice Adds / removes a specific payment token from a topic's allowlist.
    /// @dev `payToken == address(0)` controls the native-BNB entry. Covers FR-22.
    function setTopicPaymentToken(
        bytes32 topicId,
        address payToken,
        bool allowed
    ) external onlyOwner {
        _requireTopic(topicId);
        _topicPaymentTokenAllowed[topicId][payToken] = allowed;
        emit TopicPaymentTokenUpdated(topicId, payToken, allowed);
    }

    /// @notice Owner-only override of a (topic, user) expiry timestamp — used for migrations / refunds / corrections.
    /// @dev Covers FR-06 operations flow.
    function setExpiry(
        bytes32 topicId,
        address user,
        uint256 newExpiry
    ) external onlyOwner {
        _setExpiry(topicId, user, newExpiry);
    }

    /// @notice Owner-only operation that extends a (topic, user) expiry by `durationSeconds`.
    /// @dev Uses `max(oldExpiry, now) + duration` per `TopicAccessPolicyLib.extendExpiry`. Covers FR-06.
    /// @return newExpiry Resulting expiry timestamp.
    function extendExpiry(
        bytes32 topicId,
        address user,
        uint256 durationSeconds
    ) external onlyOwner returns (uint256 newExpiry) {
        if (durationSeconds == 0) {
            revert DurationZero();
        }

        _requireTopic(topicId);
        if (user == address(0)) {
            revert ZeroAddress();
        }

        uint256 oldExpiry = _expiryByTopicUser[topicId][user];
        newExpiry = TopicAccessPolicyLib.extendExpiry(oldExpiry, block.timestamp, durationSeconds);
        _setExpiry(topicId, user, newExpiry);
    }

    // ------------------------------------------------------------------ //
    //                         Runtime entry points                       //
    // ------------------------------------------------------------------ //

    /// @notice Pauses top-ups and other `whenNotPaused` functions.
    /// @dev Covers FR-14. Pausing does not stop owner operations or `executePrivilegedCall`.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Lifts a previous `pause()`.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Unprotected top-up variant (no slippage / deadline guards) — for callers that set guards off-chain.
    /// @dev Reverts for the RAMBLE path (which mandates slippage protection). Prefer the 6-argument variant.
    ///      Covers FR-05.
    /// @return newExpiry Resulting expiry timestamp for `(topicId, beneficiary)`.
    function topup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        address beneficiary
    ) external payable whenNotPaused nonReentrant returns (uint256 newExpiry) {
        return _topup(topicId, payToken, amountIn, beneficiary, 0, 0);
    }

    /// @notice Protected top-up — enforces a minimum effective WAD value and an expiry deadline.
    /// @dev Recommended entry point for all integrations. `minEffectiveValueWad > 0` required for RAMBLE payments.
    ///      Covers FR-05 / FR-05A.
    /// @param topicId Target topic.
    /// @param payToken `address(0)` for native BNB, `RAMBLE_TOKEN`, or a configured ERC20 payment token.
    /// @param amountIn Amount of `payToken` to spend (raw units, not WAD).
    /// @param beneficiary The account whose expiry will be extended.
    /// @param minEffectiveValueWad Minimum acceptable effective WAD value (slippage floor); `0` disables on non-RAMBLE paths.
    /// @param deadline Latest `block.timestamp` the call will accept; `0` disables.
    /// @return newExpiry Resulting expiry timestamp for `(topicId, beneficiary)`.
    function topup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        address beneficiary,
        uint256 minEffectiveValueWad,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256 newExpiry) {
        return _topup(topicId, payToken, amountIn, beneficiary, minEffectiveValueWad, deadline);
    }

    /// @dev Shared implementation for both `topup` variants. Flow:
    ///      1. Validate inputs (non-zero amount + beneficiary, deadline).
    ///      2. Resolve an active topic and reject paths that should not be charged
    ///         (whitelisted beneficiary / active trial / free topic / disallowed token).
    ///      3. Pull funds along the selected path:
    ///         - native BNB: require `msg.value == amountIn`, quote USD value via oracle
    ///         - RAMBLE: BSC-only, mandatory slippage guard, `safeTransferFrom` then swap to BNB via WBNB
    ///         - other ERC20: `safeTransferFrom`, measure actually-received amount (fee-on-transfer safe),
    ///           compute post-discount WAD value
    ///      4. Enforce the slippage floor and one-month minimum.
    ///      5. Bump the `(topic, user)` expiry and emit `Topup`.
    function _topup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        address beneficiary,
        uint256 minEffectiveValueWad,
        uint256 deadline
    ) internal returns (uint256 newExpiry) {
        if (amountIn == 0) {
            revert AmountZero();
        }
        if (beneficiary == address(0)) {
            revert ZeroAddress();
        }
        if (deadline != 0 && block.timestamp > deadline) {
            revert PaymentDeadlineExpired(deadline, block.timestamp);
        }

        Topic storage topic = _requireActiveTopic(topicId);
        if (_whitelistByTopicUser[topicId][beneficiary]) {
            revert WhitelistedUserNoPaymentRequired(topicId, beneficiary);
        }
        if (_isTrialActive(topicId)) {
            revert TrialPeriodNoPaymentRequired(topicId, _getEffectiveTrialEndsAt(topicId));
        }
        if (topic.monthlyPriceWad == 0) {
            revert FreeTopicNoPaymentRequired(topicId);
        }
        _requireTopicPaymentTokenAllowed(topicId, payToken);

        TopupCalc memory calc;

        if (payToken == address(0)) {
            if (msg.value != amountIn) {
                revert NativeValueMismatch(msg.value, amountIn);
            }
            calc.effectiveValueWad = _quoteBnbValueWad(amountIn);
        } else if (payToken == RAMBLE_TOKEN) {
            _requireRamblePaymentSupported();
            if (minEffectiveValueWad == 0) {
                revert RambleSlippageProtectionRequired();
            }
            if (msg.value != 0) {
                revert UnexpectedNativeValue(msg.value);
            }
            IERC20(RAMBLE_TOKEN).safeTransferFrom(msg.sender, address(this), amountIn);
            calc.effectiveValueWad = _swapRambleToBnb(amountIn);
        } else {
            if (msg.value != 0) {
                revert UnexpectedNativeValue(msg.value);
            }
            uint256 tokenBalanceBefore = IERC20(payToken).balanceOf(address(this));
            IERC20(payToken).safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 tokenAmountReceived = IERC20(payToken).balanceOf(address(this)) - tokenBalanceBefore;
            (, calc.effectiveValueWad) = _previewPaymentValueWad(payToken, tokenAmountReceived);
        }

        if (minEffectiveValueWad != 0 && calc.effectiveValueWad < minEffectiveValueWad) {
            revert EffectiveValueBelowMinimum(calc.effectiveValueWad, minEffectiveValueWad);
        }

        if (calc.effectiveValueWad < topic.monthlyPriceWad) {
            revert MinimumPaymentNotMet(calc.effectiveValueWad, topic.monthlyPriceWad);
        }

        calc.oldExpiry = _expiryByTopicUser[topicId][beneficiary];
        (calc.newExpiry,) = TopicAccessPolicyLib.computeNewExpiry(
            calc.oldExpiry, block.timestamp, calc.effectiveValueWad, ONE_MONTH, topic.monthlyPriceWad
        );
        _expiryByTopicUser[topicId][beneficiary] = calc.newExpiry;
        newExpiry = calc.newExpiry;

        emit Topup(topicId, msg.sender, beneficiary, payToken, amountIn, calc.effectiveValueWad, calc.newExpiry);
    }

    /// @notice Executes an arbitrary call from this contract (owner or configured executor only).
    /// @dev Guard scope is deliberately narrow:
    ///      - reverts `InvalidPrivilegedTarget` only for `address(0)` and `address(this)`;
    ///      - reverts `UseWithdrawERC20` when `target` has code AND the calldata selector is
    ///        `IERC20.transfer(address,uint256)` — so routine ERC20 moves go through `withdrawERC20`
    ///        for event plumbing.
    ///      All other targets (payment tokens with non-`transfer` selectors, RAMBLE pair, oracles, arbitrary
    ///      contracts) are permitted and trust the privileged caller's intent. Returns the raw `(success, returnData)`
    ///      tuple so callers can decode revert data. Covers FR-13.
    /// @param target Callee.
    /// @param value Native value to attach.
    /// @param data Calldata to forward.
    /// @return success Low-level call success flag.
    /// @return returnData Raw return bytes from `target`.
    function executePrivilegedCall(
        address target,
        uint256 value,
        bytes calldata data
    ) external nonReentrant onlyPrivilegedCaller returns (bool success, bytes memory returnData) {
        if (target == address(0) || target == address(this)) {
            revert InvalidPrivilegedTarget(target);
        }
        if (target.code.length != 0 && _selectorFromCalldata(data) == IERC20.transfer.selector) {
            revert UseWithdrawERC20(target);
        }

        (success, returnData) = target.call{ value: value }(data);

        emit PrivilegedCallExecuted(msg.sender, target, value, success);
    }

    /// @notice Withdraws native BNB from this contract to `recipient` (owner or executor only).
    /// @dev Reverts on send failure; logs via `PrivilegedWithdrawalExecuted(asset=address(0))`.
    function withdrawNative(
        address recipient,
        uint256 amount
    ) external nonReentrant onlyPrivilegedCaller {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        (bool ok,) = payable(recipient).call{ value: amount }("");
        if (!ok) {
            revert NativeWithdrawalFailed(recipient);
        }

        emit PrivilegedWithdrawalExecuted(msg.sender, address(0), recipient, amount);
    }

    /// @notice Withdraws an ERC20 from this contract to `recipient` (owner or executor only).
    /// @dev Uses `SafeERC20`; works for fee-on-transfer and non-conforming tokens.
    function withdrawERC20(
        address token,
        address recipient,
        uint256 amount
    ) external nonReentrant onlyPrivilegedCaller {
        if (token == address(0) || recipient == address(0)) {
            revert ZeroAddress();
        }

        IERC20(token).safeTransfer(recipient, amount);

        emit PrivilegedWithdrawalExecuted(msg.sender, token, recipient, amount);
    }

    // ------------------------------------------------------------------ //
    //                        Queries & quotes                            //
    // ------------------------------------------------------------------ //

    /// @notice Returns the paid expiry timestamp for `(topicId, user)`; zero means never paid.
    function getExpiry(
        bytes32 topicId,
        address user
    ) external view returns (uint256) {
        return _expiryByTopicUser[topicId][user];
    }

    /// @notice Returns whether `user` is whitelisted on `topicId` (free access).
    function isWhitelisted(
        bytes32 topicId,
        address user
    ) external view returns (bool) {
        return _whitelistByTopicUser[topicId][user];
    }

    /// @notice Returns whether `user` currently has access to `topicId`.
    /// @dev Evaluation order (see `docs/design/architecture.md` §5):
    ///      1) topic does not exist → `false`
    ///      2) whitelisted → `true`
    ///      3) trial active → `true`
    ///      4) `monthlyPriceWad == 0` → `true`
    ///      5) paid and not expired → `true`
    ///      6) otherwise → `false`
    function hasAccess(
        bytes32 topicId,
        address user
    ) public view returns (bool) {
        Topic storage topic = _topics[topicId];
        return TopicAccessPolicyLib.hasAccess(
            topic.exists,
            _whitelistByTopicUser[topicId][user],
            _getEffectiveTrialEndsAt(topicId),
            topic.monthlyPriceWad,
            _expiryByTopicUser[topicId][user],
            block.timestamp
        );
    }

    /// @notice Returns whether the topic has been registered (regardless of deactivation status).
    function topicExists(
        bytes32 topicId
    ) external view returns (bool) {
        return _topics[topicId].exists;
    }

    /// @notice Returns the monthly price (WAD) for an existing topic; reverts `TopicNotFound` if missing.
    function getTopicPriceWad(
        bytes32 topicId
    ) external view returns (uint256) {
        return _requireTopic(topicId).monthlyPriceWad;
    }

    /// @notice Returns the current RAMBLE credit discount in BPS.
    function getRambleDiscountBps() external view returns (uint16) {
        return _rambleDiscountBps;
    }

    /// @notice Number of topics ever created (used with `getTopicAt` for off-chain enumeration).
    function getTopicCount() external view returns (uint256) {
        return _topicIds.length;
    }

    /// @notice Returns `(topicId, price, key, active)` for the topic at `index` in the append-only registry.
    /// @dev Reverts `TopicIndexOutOfBounds` if `index >= getTopicCount()`.
    function getTopicAt(
        uint256 index
    ) external view returns (bytes32 topicId, uint256 monthlyPriceWad, string memory topicKey, bool active) {
        uint256 topicCount = _topicIds.length;
        if (index >= topicCount) {
            revert TopicIndexOutOfBounds(index, topicCount);
        }

        topicId = _topicIds[index];
        monthlyPriceWad = _topics[topicId].monthlyPriceWad;
        topicKey = _topicKeyById[topicId];
        active = !_topicDeactivated[topicId];
    }

    /// @notice Returns the human-readable `topicKey` previously registered for `topicId`.
    function getTopicKey(
        bytes32 topicId
    ) external view returns (string memory topicKey) {
        _requireTopic(topicId);
        topicKey = _topicKeyById[topicId];
    }

    /// @notice Returns the currently configured privileged executor (`address(0)` if none).
    function getExecutor() external view returns (address executor) {
        return _executor;
    }

    /// @notice Full payment-token view — enabled flag, token decimals, optional USD oracle + its decimals.
    function getPaymentTokenConfig(
        address token
    ) external view returns (bool enabled, uint8 tokenDecimals, address usdOracle, uint8 oracleDecimals) {
        PaymentTokenConfig memory config = _getPaymentTokenConfig(token);
        enabled = config.enabled;
        tokenDecimals = config.tokenDecimals;
        usdOracle = config.usdOracle;
        oracleDecimals = config.oracleDecimals;
    }

    /// @notice Backward-compatible view returning only the enabled flag + cached decimals.
    function getStableTokenConfig(
        address token
    ) external view returns (bool enabled, uint8 decimals) {
        PaymentTokenConfig memory config = _getPaymentTokenConfig(token);
        enabled = config.enabled;
        decimals = config.tokenDecimals;
    }

    /// @notice Returns the deprecated legacy USDC / USDT addresses from V1 storage fields.
    /// @dev Exposed for `script/UpgradeAndMigrate.s.sol`; not used by the live top-up path.
    function getLegacyStableTokens() external view returns (address legacyUsdc, address legacyUsdt) {
        return (_usdc, _usdt);
    }

    /// @notice Returns the configured BNB/USD oracle and its acceptable staleness (seconds).
    function getOracleConfig() external view returns (address bnbUsdOracle, uint256 maxOracleDelay) {
        return (_bnbUsdOracle, _maxOracleDelay);
    }

    /// @notice Returns the global trial cutoff timestamp (seconds); `0` disables it.
    function getGlobalTrialEndsAt() external view returns (uint256) {
        return _globalTrialEndsAt;
    }

    /// @notice Returns the raw topic-level trial cutoff stored for this topic (ignores the global cutoff).
    /// @dev Use `getEffectiveTrialEndsAt` for the cutoff actually applied to `hasAccess` (`max(global, topic)`).
    function getTopicTrialEndsAt(
        bytes32 topicId
    ) external view returns (uint256) {
        _requireTopic(topicId);
        return _topicTrialEndsAt[topicId];
    }

    /// @notice Returns the trial cutoff actually applied to `topicId` — the topic-level value when non-zero, otherwise the global value.
    function getEffectiveTrialEndsAt(
        bytes32 topicId
    ) external view returns (uint256) {
        _requireTopic(topicId);
        return _getEffectiveTrialEndsAt(topicId);
    }

    /// @notice Returns whether the per-topic payment allowlist is enabled for `topicId`.
    function getTopicPaymentAllowlistEnabled(
        bytes32 topicId
    ) external view returns (bool) {
        _requireTopic(topicId);
        return _topicPaymentAllowlistEnabled[topicId];
    }

    /// @notice Returns whether `payToken` is allowed to pay for `topicId` under the current allowlist state.
    function isTopicPaymentTokenAllowed(
        bytes32 topicId,
        address payToken
    ) external view returns (bool) {
        _requireTopic(topicId);
        return _isTopicPaymentTokenAllowed(topicId, payToken);
    }

    /// @notice Returns the configured RAMBLE/WBNB PancakeSwap V2 pair (`address(0)` outside BSC).
    function getRamblePair() external view returns (address) {
        return _rambleWbnbPair;
    }

    /// @notice Quotes the minimum BNB (wei) needed to buy one month on `topicId`.
    /// @dev Returns `0` if payment is not required (free topic, whitelisted, or active trial).
    ///      Rounds up so the quote is safe to submit verbatim.
    function quoteMinBnbForOneMonth(
        bytes32 topicId
    ) external view returns (uint256 minBnbWei) {
        Topic storage topic = _requireActiveTopic(topicId);
        if (_isNoPaymentRequired(topicId, topic.monthlyPriceWad)) {
            return 0;
        }
        _requireTopicPaymentTokenAllowed(topicId, address(0));

        (uint256 bnbUsdPrice, uint8 oracleDecimals) = _getBnbPriceChecked();
        uint256 oracleScale = WadScaleLib.pow10(oracleDecimals);

        minBnbWei = Math.mulDiv(topic.monthlyPriceWad, oracleScale, bnbUsdPrice, Math.Rounding.Ceil);
    }

    /// @notice Quotes the minimum RAMBLE amount needed to buy one month on `topicId`. BSC-only.
    /// @dev Iterates `RamblePricingLib.quoteMinAmountForTargetValue`, bounded by `MAX_QUOTE_SEARCH_STEPS`.
    ///      Returns `0` if payment is not required; reverts `QuoteUnavailable` if search exhausts.
    function quoteMinRambleForOneMonth(
        bytes32 topicId
    ) external view returns (uint256 minRambleAmount) {
        Topic storage topic = _requireActiveTopic(topicId);
        uint256 monthlyPriceWad = topic.monthlyPriceWad;
        if (_isNoPaymentRequired(topicId, monthlyPriceWad)) {
            return 0;
        }
        _requireTopicPaymentTokenAllowed(topicId, RAMBLE_TOKEN);
        _requireRamblePaymentSupported();

        minRambleAmount = _quoteMinRambleForValueWad(monthlyPriceWad);
    }

    /// @dev Binary-searches for the minimum RAMBLE amount whose post-discount WAD value is at least
    ///      `monthlyPriceWad`. Loop iterations are bounded by `MAX_QUOTE_SEARCH_STEPS`; exhaustion reverts.
    function _quoteMinRambleForValueWad(
        uint256 monthlyPriceWad
    ) internal view returns (uint256 minRambleAmount) {
        (bool found, uint256 quotedMinAmount) =
            RamblePricingLib.quoteMinAmountForTargetValue(monthlyPriceWad, MAX_QUOTE_SEARCH_STEPS, _quoteRambleValueWad);
        if (!found) {
            revert QuoteUnavailable();
        }

        return quotedMinAmount;
    }

    /// @notice Unified quote across all payment paths: native BNB, RAMBLE, or a configured ERC20.
    /// @dev Delegates to the path-specific quoter; reverts `UnsupportedPayToken` for an unregistered ERC20.
    /// @param topicId Target topic.
    /// @param payToken `address(0)` for native BNB, `RAMBLE_TOKEN`, or a configured payment token.
    /// @return minTokenAmount Minimum raw-unit amount needed to buy one month, rounded up.
    function quoteMinTokenForOneMonth(
        bytes32 topicId,
        address payToken
    ) external view returns (uint256 minTokenAmount) {
        Topic storage topic = _requireActiveTopic(topicId);
        uint256 monthlyPriceWad = topic.monthlyPriceWad;
        if (_isNoPaymentRequired(topicId, monthlyPriceWad)) {
            return 0;
        }
        _requireTopicPaymentTokenAllowed(topicId, payToken);

        if (payToken == address(0)) {
            (uint256 bnbUsdPrice, uint8 oracleDecimals) = _getBnbPriceChecked();
            return Math.mulDiv(monthlyPriceWad, WadScaleLib.pow10(oracleDecimals), bnbUsdPrice, Math.Rounding.Ceil);
        }
        if (payToken == RAMBLE_TOKEN) {
            _requireRamblePaymentSupported();
            return _quoteMinRambleForValueWad(monthlyPriceWad);
        }
        if (!_paymentTokenEnabled[payToken]) {
            revert UnsupportedPayToken(payToken);
        }

        minTokenAmount = _quoteMinConfiguredTokenAmount(payToken, monthlyPriceWad);
    }

    /// @notice Previews the outcome of a hypothetical `topup`: raw value, post-discount effective value, seconds added.
    /// @dev Returns `(0, 0, 0)` when payment is not required (free topic, whitelisted, active trial). Does not consider slippage.
    /// @param topicId Target topic.
    /// @param payToken Payment token (`address(0)` = native BNB).
    /// @param amountIn Raw amount the caller would send.
    /// @return rawValueWad Pre-discount WAD value corresponding to `amountIn`.
    /// @return effectiveValueWad Post-discount WAD value actually credited.
    /// @return secondsAdded Number of seconds that would be added to the expiry.
    function previewTopup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn
    ) external view returns (uint256 rawValueWad, uint256 effectiveValueWad, uint256 secondsAdded) {
        Topic storage topic = _requireActiveTopic(topicId);

        if (_isNoPaymentRequired(topicId, topic.monthlyPriceWad) || amountIn == 0) {
            return (0, 0, 0);
        }
        _requireTopicPaymentTokenAllowed(topicId, payToken);

        (rawValueWad, effectiveValueWad) = _previewPaymentValueWad(payToken, amountIn);
        (, secondsAdded) =
            TopicAccessPolicyLib.computeNewExpiry(0, 0, effectiveValueWad, ONE_MONTH, topic.monthlyPriceWad);
    }

    /// @dev Validates BPS bounds (`0 < bps <= BPS_BASE`) and stores.
    function _setRambleDiscountBps(
        uint16 newDiscountBps
    ) internal {
        if (newDiscountBps == 0 || newDiscountBps > uint16(BPS_BASE)) {
            revert InvalidDiscountBps(newDiscountBps);
        }

        _rambleDiscountBps = newDiscountBps;

        emit RambleDiscountUpdated(newDiscountBps);
    }

    /// @dev Accepts `address(0)` to clear the executor (owner-only operations still work).
    function _setExecutor(
        address executor_
    ) internal {
        _executor = executor_;

        emit ExecutorUpdated(executor_);
    }

    /// @dev Runs a full `_readOraclePriceChecked` round-trip against the proposed oracle before storing —
    ///      rejects interface-incompatible / stale / invalid-round oracles at configuration time.
    function _setOracleConfig(
        address bnbUsdOracle_,
        uint256 maxOracleDelay_
    ) internal {
        if (bnbUsdOracle_ == address(0) || maxOracleDelay_ == 0) {
            revert InvalidOracleConfig();
        }

        _readOraclePriceChecked(bnbUsdOracle_, maxOracleDelay_);
        _bnbUsdOracle = bnbUsdOracle_;
        _maxOracleDelay = maxOracleDelay_;

        emit OracleConfigUpdated(bnbUsdOracle_, maxOracleDelay_);
    }

    /// @dev Shared setter for `setPaymentToken` / `setStableToken`. When enabling, reads + validates decimals,
    ///      optionally enforces and probes a USD oracle, and writes the resulting `PaymentTokenConfig`.
    ///      `requireOracle=true` → mandatory oracle (FR-07A); `false` → 1:1 stable compatibility path.
    function _setPaymentToken(
        address token,
        bool enabled,
        address usdOracle,
        bool requireOracle
    ) internal returns (uint8 tokenDecimals, uint8 oracleDecimals) {
        if (token == address(0)) {
            revert ZeroAddress();
        }
        if (token == RAMBLE_TOKEN) {
            revert InvalidStableToken(token);
        }

        PaymentTokenConfig memory config = _getPaymentTokenConfig(token);
        tokenDecimals = config.tokenDecimals;
        address oracleToStore = config.usdOracle;
        oracleDecimals = config.oracleDecimals;
        if (enabled) {
            if (token.code.length == 0) {
                revert InvalidStableToken(token);
            }
            tokenDecimals = _readTokenDecimals(token);
            WadScaleLib.validateDecimals(tokenDecimals);

            if (requireOracle && usdOracle == address(0)) {
                revert PaymentTokenOracleRequired(token);
            }

            oracleToStore = usdOracle;
            oracleDecimals = 0;
            if (oracleToStore != address(0)) {
                (, oracleDecimals) = _readOraclePriceChecked(oracleToStore, _maxOracleDelay);
            }
        }

        config.enabled = enabled;
        config.tokenDecimals = tokenDecimals;
        config.usdOracle = oracleToStore;
        config.oracleDecimals = oracleDecimals;
        _storePaymentTokenConfig(token, config);

        emit PaymentTokenUpdated(token, enabled, oracleToStore, tokenDecimals, oracleDecimals);
    }

    /// @dev Called from `initialize` on BSC to auto-bind the canonical pair. No-op on other chains so the
    ///      contract can be deployed cross-chain without tripping RAMBLE-specific checks.
    function _setDefaultRamblePair() internal {
        if (!_isBscChain()) {
            return;
        }

        _rambleWbnbPair = DEFAULT_RAMBLE_WBNB_PAIR;
        emit RamblePairUpdated(DEFAULT_RAMBLE_WBNB_PAIR);

        if (DEFAULT_RAMBLE_WBNB_PAIR.code.length > 0) {
            _validateRamblePair(DEFAULT_RAMBLE_WBNB_PAIR);
        }
    }

    /// @dev Shared implementation for `setRamblePair`; fail-fast on non-BSC or `address(0)`.
    function _setRamblePair(
        address rambleWbnbPair_
    ) internal {
        _requireRamblePaymentSupported();
        if (rambleWbnbPair_ == address(0)) {
            revert ZeroAddress();
        }
        _validateRamblePair(rambleWbnbPair_);

        _rambleWbnbPair = rambleWbnbPair_;

        emit RamblePairUpdated(rambleWbnbPair_);
    }

    /// @dev Asserts a pair contract is valid for the RAMBLE path:
    ///      - it is deployed (has code),
    ///      - one leg is `RAMBLE_TOKEN` and the other is the pinned `BSC_WBNB`,
    ///      - and the wrapped-native leg still exposes `withdraw(uint256)` so we can unwrap WBNB post-swap.
    ///      Covers NFR-05.
    function _validateRamblePair(
        address rambleWbnbPair_
    ) internal {
        if (rambleWbnbPair_.code.length == 0) {
            revert RamblePairNotConfigured(rambleWbnbPair_);
        }

        IPancakePairV2 pair = IPancakePairV2(rambleWbnbPair_);
        address token0 = pair.token0();
        address token1 = pair.token1();
        address wrappedNative;
        if (token0 != RAMBLE_TOKEN && token1 != RAMBLE_TOKEN) {
            revert PairTokenMismatch(token0, token1, RAMBLE_TOKEN);
        }
        if (token0 == RAMBLE_TOKEN) {
            wrappedNative = token1;
        } else {
            wrappedNative = token0;
        }

        if (wrappedNative != BSC_WBNB) {
            revert InvalidWrappedNative(wrappedNative, BSC_WBNB);
        }
        if (wrappedNative.code.length == 0) {
            revert WrappedNativeWithdrawFailed(wrappedNative);
        }

        (bool canWithdraw,) = wrappedNative.call(abi.encodeWithSignature("withdraw(uint256)", 0));
        if (!canWithdraw) {
            revert WrappedNativeWithdrawFailed(wrappedNative);
        }
    }

    /// @dev Reads ERC20 decimals via `IERC20Metadata`; extracted for clarity.
    function _readTokenDecimals(
        address token
    ) internal view returns (uint8 decimals_) {
        decimals_ = IERC20Metadata(token).decimals();
    }

    /// @dev Shared implementation for `createTopic` / `createTopicByKey` — validates id, prevents duplicates,
    ///      appends to `_topicIds`, emits `TopicCreated`.
    function _createTopic(
        bytes32 topicId,
        uint256 monthlyPriceWad
    ) internal {
        if (topicId == bytes32(0)) {
            revert InvalidTopicId();
        }
        if (_topics[topicId].exists) {
            revert TopicAlreadyExists(topicId);
        }

        _topics[topicId] = Topic({ exists: true, monthlyPriceWad: monthlyPriceWad });
        _topicIds.push(topicId);

        emit TopicCreated(topicId, monthlyPriceWad);
    }

    /// @dev `keccak256(bytes(topicKey))` with a guard against empty keys.
    function _hashTopicKey(
        string memory topicKey
    ) internal pure returns (bytes32) {
        if (bytes(topicKey).length == 0) {
            revert EmptyTopicKey();
        }

        return keccak256(bytes(topicKey));
    }

    /// @dev Stores the topic key after verifying its hash matches `topicId` — guards against typo'd pairs.
    function _registerTopicKey(
        bytes32 topicId,
        string memory topicKey
    ) internal {
        bytes32 derivedTopicId = _hashTopicKey(topicKey);
        if (derivedTopicId != topicId) {
            revert TopicKeyMismatch(topicId, derivedTopicId);
        }

        _topicKeyById[topicId] = topicKey;
        emit TopicKeyRegistered(topicId, topicKey);
    }

    /// @dev Routes a preview computation into the path-appropriate quoter:
    ///      native (1:1 effective), RAMBLE (AMM + discount), or an oracle-priced ERC20.
    function _previewPaymentValueWad(
        address payToken,
        uint256 amountIn
    ) internal view returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        if (payToken == address(0)) {
            rawValueWad = _quoteBnbValueWad(amountIn);
            effectiveValueWad = rawValueWad;
            return (rawValueWad, effectiveValueWad);
        }

        if (payToken == RAMBLE_TOKEN) {
            _requireRamblePaymentSupported();
            return _quoteRambleValueWad(amountIn);
        }

        if (_getPaymentTokenConfig(payToken).enabled) {
            return _quoteConfiguredTokenValueWad(payToken, amountIn);
        }

        revert UnsupportedPayToken(payToken);
    }

    /// @dev Prices a configured ERC20 via its USD oracle; falls back to 1:1 stable when no oracle is bound.
    function _quoteConfiguredTokenValueWad(
        address payToken,
        uint256 amountIn
    ) internal view returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        PaymentTokenConfig memory config = _getPaymentTokenConfig(payToken);
        uint8 tokenDecimals = config.tokenDecimals;
        address usdOracle = config.usdOracle;

        if (usdOracle == address(0)) {
            return _quoteStableValueWad(amountIn, tokenDecimals);
        }

        (uint256 tokenUsdPrice, uint8 oracleDecimals) = _readOraclePriceChecked(usdOracle, _maxOracleDelay);
        uint256 oracleScale = WadScaleLib.pow10(oracleDecimals);
        uint256 amountWad = WadScaleLib.toWad(amountIn, tokenDecimals);

        rawValueWad = Math.mulDiv(amountWad, tokenUsdPrice, oracleScale);
        effectiveValueWad = rawValueWad;
    }

    /// @dev 1:1 stablecoin path — just rescales `amountIn` to WAD using the cached decimals.
    function _quoteStableValueWad(
        uint256 amountIn,
        uint8 tokenDecimals
    ) internal pure returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        rawValueWad = WadScaleLib.toWad(amountIn, tokenDecimals);
        effectiveValueWad = rawValueWad;
    }

    /// @dev Inverse of `_quoteConfiguredTokenValueWad`: given a required WAD value, returns the minimum raw
    ///      token amount that buys it (rounded up). Used by `quoteMinTokenForOneMonth`.
    function _quoteMinConfiguredTokenAmount(
        address payToken,
        uint256 requiredValueWad
    ) internal view returns (uint256 minTokenAmount) {
        PaymentTokenConfig memory config = _getPaymentTokenConfig(payToken);
        uint8 tokenDecimals = config.tokenDecimals;
        address usdOracle = config.usdOracle;
        if (usdOracle == address(0)) {
            return WadScaleLib.fromWadRoundUp(requiredValueWad, tokenDecimals);
        }

        (uint256 tokenUsdPrice, uint8 oracleDecimals) = _readOraclePriceChecked(usdOracle, _maxOracleDelay);
        uint256 requiredTokenWad =
            Math.mulDiv(requiredValueWad, WadScaleLib.pow10(oracleDecimals), tokenUsdPrice, Math.Rounding.Ceil);

        minTokenAmount = WadScaleLib.fromWadRoundUp(requiredTokenWad, tokenDecimals);
    }

    /// @dev Converts a BNB wei amount into its WAD-USD value using the BNB/USD oracle + cached scaling.
    function _quoteBnbValueWad(
        uint256 bnbAmountWei
    ) internal view returns (uint256) {
        (uint256 bnbUsdPrice, uint8 oracleDecimals) = _getBnbPriceChecked();
        uint256 oracleScale = WadScaleLib.pow10(oracleDecimals);

        return Math.mulDiv(bnbAmountWei, bnbUsdPrice, oracleScale);
    }

    /// @dev Prices RAMBLE → WBNB via the PancakeSwap V2 AMM curve, USD-prices the WBNB, then divides by
    ///      `_rambleDiscountBps / BPS_BASE` to produce the credited value:
    ///      `effectiveValueWad = rawValueWad * BPS_BASE / _rambleDiscountBps`.
    ///      With `bps = 9500` the caller is credited `~100/95 ≈ 105.26%` of raw value — the protocol pays a
    ///      ~5.26% premium to RAMBLE payers. `bps = BPS_BASE` gives 1:1 credit.
    function _quoteRambleValueWad(
        uint256 rambleAmount
    ) internal view returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        _requireRamblePaymentSupported();
        uint256 wbnbOut = _estimateWbnbOutFromRamble(rambleAmount);
        rawValueWad = _quoteBnbValueWad(wbnbOut);
        effectiveValueWad = Math.mulDiv(rawValueWad, BPS_BASE, _rambleDiscountBps);
    }

    /// @dev Pure AMM computation for the RAMBLE → WBNB direction using `V2_FEE_*` and current reserves.
    function _estimateWbnbOutFromRamble(
        uint256 rambleAmount
    ) internal view returns (uint256 wbnbOut) {
        IPancakePairV2 pair = _getConfiguredRamblePair();
        (,, uint256 reserveIn, uint256 reserveOut) = _getRamblePairState(pair);
        wbnbOut =
            RamblePricingLib.getV2AmountOut(rambleAmount, reserveIn, reserveOut, V2_FEE_NUMERATOR, V2_FEE_DENOMINATOR);
    }

    /// @dev Actually performs the RAMBLE → WBNB → native BNB swap for `_topup`:
    ///      1. `safeTransfer` RAMBLE to the pair; measure the amount the pair actually received
    ///         (fee-on-transfer safe).
    ///      2. Re-quote the AMM output with the measured input and call `pair.swap(...)`.
    ///      3. Measure received WBNB, unwrap it via `withdraw(uint256)`, and measure received native.
    ///      4. USD-price the native amount and apply the RAMBLE discount.
    ///      Uses the before/after balance deltas (not the raw `amountIn`) at each stage to stay correct under
    ///      fee-on-transfer RAMBLE tokens or a malicious / unusual WBNB.
    function _swapRambleToBnb(
        uint256 rambleAmount
    ) internal returns (uint256 effectiveValueWad) {
        _requireRamblePaymentSupported();
        IPancakePairV2 pair = _getConfiguredRamblePair();
        (bool rambleIsToken0, address wrappedNative, uint256 reserveIn, uint256 reserveOut) = _getRamblePairState(pair);

        uint256 pairRambleBalanceBefore = IERC20(RAMBLE_TOKEN).balanceOf(address(pair));
        IERC20(RAMBLE_TOKEN).safeTransfer(address(pair), rambleAmount);
        uint256 amountInActual = IERC20(RAMBLE_TOKEN).balanceOf(address(pair)) - pairRambleBalanceBefore;

        uint256 expectedWbnbOut = RamblePricingLib.getV2AmountOut(
            amountInActual, reserveIn, reserveOut, V2_FEE_NUMERATOR, V2_FEE_DENOMINATOR
        );
        if (expectedWbnbOut == 0) {
            revert PairLiquidityTooLow();
        }

        uint256 wrappedBalanceBefore = IERC20(wrappedNative).balanceOf(address(this));
        if (rambleIsToken0) {
            pair.swap(0, expectedWbnbOut, address(this), bytes(""));
        } else {
            pair.swap(expectedWbnbOut, 0, address(this), bytes(""));
        }

        uint256 wrappedReceived = IERC20(wrappedNative).balanceOf(address(this)) - wrappedBalanceBefore;
        if (wrappedReceived == 0) {
            revert PairLiquidityTooLow();
        }

        uint256 nativeBalanceBefore = address(this).balance;
        (bool ok,) = wrappedNative.call(abi.encodeWithSignature("withdraw(uint256)", wrappedReceived));
        if (!ok) {
            revert WrappedNativeWithdrawFailed(wrappedNative);
        }
        uint256 nativeReceived = address(this).balance - nativeBalanceBefore;
        if (nativeReceived == 0) {
            revert WrappedNativeWithdrawFailed(wrappedNative);
        }

        uint256 rawValueWad = _quoteBnbValueWad(nativeReceived);
        effectiveValueWad = Math.mulDiv(rawValueWad, BPS_BASE, _rambleDiscountBps);
    }

    /// @dev Reads the pair's tokens + reserves and normalises them so RAMBLE is always `reserveIn`.
    ///      Reverts `PairTokenMismatch` if neither leg is RAMBLE, and `PairLiquidityTooLow` on zero reserves.
    function _getRamblePairState(
        IPancakePairV2 pair
    ) internal view returns (bool rambleIsToken0, address wrappedNative, uint256 reserveIn, uint256 reserveOut) {
        address token0 = pair.token0();
        address token1 = pair.token1();
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        if (token0 == RAMBLE_TOKEN) {
            rambleIsToken0 = true;
            wrappedNative = token1;
            reserveIn = uint256(reserve0);
            reserveOut = uint256(reserve1);
        } else if (token1 == RAMBLE_TOKEN) {
            wrappedNative = token0;
            reserveIn = uint256(reserve1);
            reserveOut = uint256(reserve0);
        } else {
            revert PairTokenMismatch(token0, token1, RAMBLE_TOKEN);
        }

        if (reserveIn == 0 || reserveOut == 0) {
            revert PairLiquidityTooLow();
        }
    }

    /// @dev Returns the configured RAMBLE pair after asserting it exists and has code. BSC-only.
    function _getConfiguredRamblePair() internal view returns (IPancakePairV2 pair) {
        _requireRamblePaymentSupported();
        address pairAddress = _rambleWbnbPair;
        if (pairAddress == address(0) || pairAddress.code.length == 0) {
            revert RamblePairNotConfigured(pairAddress);
        }
        pair = IPancakePairV2(pairAddress);
    }

    /// @dev Thin wrapper over `_readOraclePriceChecked` for the BNB/USD oracle configured at init.
    function _getBnbPriceChecked() internal view returns (uint256 bnbUsdPrice, uint8 oracleDecimals) {
        return _readOraclePriceChecked(_bnbUsdOracle, _maxOracleDelay);
    }

    /// @dev Aggregates the split payment-token mappings into the `PaymentTokenConfig` struct.
    function _getPaymentTokenConfig(
        address token
    ) internal view returns (PaymentTokenConfig memory config) {
        config.enabled = _paymentTokenEnabled[token];
        config.tokenDecimals = _paymentTokenDecimals[token];
        config.usdOracle = _paymentTokenOracle[token];
        config.oracleDecimals = _paymentTokenOracleDecimals[token];
    }

    /// @dev Mirror of `_getPaymentTokenConfig`; writes the struct into the split mappings.
    function _storePaymentTokenConfig(
        address token,
        PaymentTokenConfig memory config
    ) internal {
        _paymentTokenEnabled[token] = config.enabled;
        _paymentTokenDecimals[token] = config.tokenDecimals;
        _paymentTokenOracle[token] = config.usdOracle;
        _paymentTokenOracleDecimals[token] = config.oracleDecimals;
    }

    /// @dev Returns true if the topic is free, on a trial, or otherwise exempt from payment — used to short-circuit quotes.
    function _isNoPaymentRequired(
        bytes32 topicId,
        uint256 monthlyPriceWad
    ) internal view returns (bool) {
        return
            TopicAccessPolicyLib.isNoPaymentRequired(
                monthlyPriceWad, _getEffectiveTrialEndsAt(topicId), block.timestamp
            );
    }

    /// @dev Returns whether a token is allowed to pay for a topic — short-circuit for unconfigured allowlists.
    function _isTopicPaymentTokenAllowed(
        bytes32 topicId,
        address payToken
    ) internal view returns (bool) {
        return TopicAccessPolicyLib.isTopicPaymentTokenAllowed(
            _topicPaymentAllowlistEnabled[topicId], _topicPaymentTokenAllowed[topicId][payToken]
        );
    }

    /// @dev Asserts `_isTopicPaymentTokenAllowed`; reverts `PayTokenNotAllowedForTopic` on failure.
    function _requireTopicPaymentTokenAllowed(
        bytes32 topicId,
        address payToken
    ) internal view {
        if (!_isTopicPaymentTokenAllowed(topicId, payToken)) {
            revert PayTokenNotAllowedForTopic(topicId, payToken);
        }
    }

    /// @dev Returns whether `(effective trial end) > now`.
    function _isTrialActive(
        bytes32 topicId
    ) internal view returns (bool) {
        return
            TopicAccessPolicyLib.effectiveTrialEndsAt(_globalTrialEndsAt, _topicTrialEndsAt[topicId]) > block.timestamp;
    }

    /// @dev Cheap BSC check used to gate the RAMBLE path.
    function _isBscChain() internal view returns (bool) {
        return block.chainid == BSC_CHAIN_ID;
    }

    /// @dev Fail-fast guard used by every RAMBLE-touching function.
    function _requireRamblePaymentSupported() internal view {
        if (!_isBscChain()) {
            revert RambleOnlySupportedOnBsc(block.chainid);
        }
    }

    /// @dev Effective cutoff is `max(global, topic-level)` — topic values can only extend the global trial.
    function _getEffectiveTrialEndsAt(
        bytes32 topicId
    ) internal view returns (uint256) {
        return TopicAccessPolicyLib.effectiveTrialEndsAt(_globalTrialEndsAt, _topicTrialEndsAt[topicId]);
    }

    /// @dev Robust Chainlink read used both on config (probe) and on every quote. Validates:
    ///      - the oracle is a deployed contract,
    ///      - `decimals()` is implemented and within WAD-scaling bounds,
    ///      - `latestRoundData()` is implemented,
    ///      - `answer > 0` and `updatedAt` is in the past,
    ///      - freshness (`now - updatedAt <= maxOracleDelay_`),
    ///      - the round has settled (`answeredInRound >= roundId`).
    ///      Covers NFR-04.
    function _readOraclePriceChecked(
        address oracleAddress,
        uint256 maxOracleDelay_
    ) internal view returns (uint256 bnbUsdPrice, uint8 oracleDecimals) {
        if (oracleAddress.code.length == 0) {
            revert InvalidOracle(oracleAddress);
        }

        IAggregatorV3 oracle = IAggregatorV3(oracleAddress);

        try oracle.decimals() returns (uint8 decimals_) {
            oracleDecimals = decimals_;
        } catch {
            revert InvalidOracle(oracleAddress);
        }

        WadScaleLib.validateDecimals(oracleDecimals);

        uint80 roundId;
        int256 answer;
        uint256 updatedAt;
        uint80 answeredInRound;
        try oracle.latestRoundData() returns (
            uint80 roundId_, int256 answer_, uint256, uint256 updatedAt_, uint80 answeredInRound_
        ) {
            roundId = roundId_;
            answer = answer_;
            updatedAt = updatedAt_;
            answeredInRound = answeredInRound_;
        } catch {
            revert InvalidOracle(oracleAddress);
        }

        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) {
            revert OraclePriceInvalid();
        }
        if (block.timestamp - updatedAt > maxOracleDelay_) {
            revert OraclePriceStale(updatedAt, block.timestamp, maxOracleDelay_);
        }
        if (answeredInRound < roundId) {
            revert OracleRoundInvalid(roundId, answeredInRound);
        }

        bnbUsdPrice = uint256(answer);
    }

    /// @dev Owner-only write of an expiry; emits `ExpiryUpdated` with old + new values for auditability.
    function _setExpiry(
        bytes32 topicId,
        address user,
        uint256 newExpiry
    ) internal {
        _requireTopic(topicId);
        if (user == address(0)) {
            revert ZeroAddress();
        }

        uint256 oldExpiry = _expiryByTopicUser[topicId][user];
        _expiryByTopicUser[topicId][user] = newExpiry;
        emit ExpiryUpdated(topicId, user, oldExpiry, newExpiry);
    }

    /// @dev Loads the topic and reverts `TopicNotFound` when missing.
    function _requireTopic(
        bytes32 topicId
    ) internal view returns (Topic storage topic) {
        topic = _topics[topicId];
        if (!topic.exists) {
            revert TopicNotFound(topicId);
        }
    }

    /// @dev Loads the topic and reverts `TopicNotFound` or `TopicIsDeactivated` as appropriate.
    function _requireActiveTopic(
        bytes32 topicId
    ) internal view returns (Topic storage topic) {
        topic = _requireTopic(topicId);
        if (_topicDeactivated[topicId]) {
            revert TopicIsDeactivated(topicId);
        }
    }

    /// @dev UUPS upgrade gate — only owner, only non-zero implementation. Covers FR-15.
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyOwner {
        if (newImplementation == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @dev Reads the first 4 bytes of `data` as the selector; used by `executePrivilegedCall` to block
    ///      plain ERC20 `transfer` patterns that would bypass `withdrawERC20` event plumbing.
    function _selectorFromCalldata(
        bytes calldata data
    ) internal pure returns (bytes4 selector) {
        if (data.length < 4) {
            return bytes4(0);
        }

        assembly {
            selector := calldataload(data.offset)
        }
    }

    /// @dev Access gate: allow either the current `owner()` or the optional `_executor`.
    modifier onlyPrivilegedCaller() {
        if (msg.sender != owner() && msg.sender != _executor) {
            revert NotExecutor(msg.sender);
        }
        _;
    }
}
