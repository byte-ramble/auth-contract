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

contract TopicAccessManagerUpgradeable is Initializable, UUPSUpgradeable, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Topic {
        bool exists;
        uint256 monthlyPriceWad;
    }

    struct PaymentTokenConfig {
        bool enabled;
        uint8 tokenDecimals;
        address usdOracle;
        uint8 oracleDecimals;
    }

    struct TopupCalc {
        uint256 effectiveValueWad;
        uint256 oldExpiry;
        uint256 newExpiry;
    }

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS_BASE = 10_000;
    uint256 public constant ONE_MONTH = 30 days;
    uint256 public constant ONE_YEAR = 365 days;
    uint256 public constant MONTHS_PER_YEAR = 12;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant BSC_CHAIN_ID = 56;

    address public constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant RAMBLE_TOKEN = 0x1A8C391f6c603894108fcE14A52E9Bf804c67777;
    address public constant DEFAULT_RAMBLE_WBNB_PAIR = 0x185e706a55d04815e7e10b506A5a4d8d1153aeAD;
    uint16 public constant DEFAULT_RAMBLE_DISCOUNT_BPS = 9000;

    uint256 private constant V2_FEE_NUMERATOR = 9975;
    uint256 private constant V2_FEE_DENOMINATOR = 10_000;
    uint256 private constant MAX_QUOTE_SEARCH_STEPS = 64;

    mapping(bytes32 => Topic) private _topics;
    mapping(bytes32 => mapping(address => uint256)) private _expiryByTopicUser;
    mapping(bytes32 => mapping(address => bool)) private _whitelistByTopicUser;

    uint16 private _rambleDiscountBps;

    address private _executor;

    // Deprecated legacy token config storage (kept for upgrade-safe layout).
    address private _usdc;
    address private _usdt;
    address private _ramble;

    // Deprecated legacy token decimals storage (kept for upgrade-safe layout).
    uint8 private _usdcDecimals;
    uint8 private _usdtDecimals;
    uint8 private _rambleDecimals;

    address private _bnbUsdOracle;
    address private _rambleWbnbPair;
    uint256 private _maxOracleDelay;

    mapping(address => bool) private _paymentTokenEnabled;
    mapping(address => uint8) private _paymentTokenDecimals;

    mapping(bytes32 => string) private _topicKeyById;
    bytes32[] private _topicIds;
    mapping(address => address) private _paymentTokenOracle;
    mapping(address => uint8) private _paymentTokenOracleDecimals;
    uint256 private _globalTrialEndsAt;
    mapping(bytes32 => uint256) private _topicTrialEndsAt;
    mapping(bytes32 => bool) private _topicPaymentAllowlistEnabled;
    mapping(bytes32 => mapping(address => bool)) private _topicPaymentTokenAllowed;

    mapping(bytes32 => bool) private _topicDeactivated;

    mapping(bytes32 => uint256) private _annualPriceWadByTopic;

    uint256[29] private __gap;

    error ZeroAddress();
    error EmptyTopicKey();
    error InvalidTopicId();
    error TopicNotFound(bytes32 topicId);
    error TopicAlreadyExists(bytes32 topicId);
    error AmountZero();
    error UnsupportedPayToken(address payToken);
    error NativeValueMismatch(uint256 msgValue, uint256 amountIn);
    error UnexpectedNativeValue(uint256 msgValue);
    error PaymentDeadlineExpired(uint256 deadline, uint256 nowTimestamp);
    error FreeTopicNoPaymentRequired(bytes32 topicId);
    error TrialPeriodNoPaymentRequired(bytes32 topicId, uint256 trialEndsAt);
    error WhitelistedUserNoPaymentRequired(bytes32 topicId, address user);
    error MinimumPaymentNotMet(uint256 effectiveValueWad, uint256 monthlyPriceWad);
    error EffectiveValueBelowMinimum(uint256 effectiveValueWad, uint256 minEffectiveValueWad);
    error InvalidDiscountBps(uint16 discountBps);
    error InvalidOracleConfig();
    error InvalidOracle(address oracle);
    error PaymentTokenOracleRequired(address token);
    error PayTokenNotAllowedForTopic(bytes32 topicId, address payToken);
    error RambleOnlySupportedOnBsc(uint256 chainId);
    error NotExecutor(address caller);
    error InvalidPrivilegedTarget(address target);
    error InvalidStableToken(address token);
    error DurationZero();
    error OraclePriceInvalid();
    error OraclePriceStale(uint256 updatedAt, uint256 nowTimestamp, uint256 maxOracleDelay);
    error OracleRoundInvalid(uint80 roundId, uint80 answeredInRound);
    error TopicKeyMismatch(bytes32 topicId, bytes32 derivedTopicId);
    error TopicIndexOutOfBounds(uint256 index, uint256 count);
    error PairTokenMismatch(address token0, address token1, address ramble);
    error InvalidWrappedNative(address wrappedNative, address expectedWrappedNative);
    error RamblePairNotConfigured(address pair);
    error PairLiquidityTooLow();
    error WrappedNativeWithdrawFailed(address wrappedNative);
    error QuoteUnavailable();
    error RambleSlippageProtectionRequired();
    error TopicIsDeactivated(bytes32 topicId);
    error TopicAlreadyActive(bytes32 topicId);
    error BatchSizeExceeded(uint256 provided, uint256 max);
    error NativeWithdrawalFailed(address recipient);
    error UseWithdrawERC20(address token);

    event TopicCreated(bytes32 indexed topicId, uint256 monthlyPriceWad);
    event TopicKeyRegistered(bytes32 indexed topicId, string topicKey);
    event TopicPriceUpdated(bytes32 indexed topicId, uint256 newPriceWad);
    event TopicAnnualPriceUpdated(bytes32 indexed topicId, uint256 newAnnualPriceWad);
    event WhitelistUpdated(bytes32 indexed topicId, address indexed user, bool isWhitelisted);

    event RambleDiscountUpdated(uint16 newBps);

    event ExecutorUpdated(address indexed executor);

    event OracleConfigUpdated(address indexed oracle, uint256 maxOracleDelay);

    event StableTokenUpdated(address indexed token, bool enabled, uint8 decimals);
    event PaymentTokenUpdated(
        address indexed token, bool enabled, address indexed usdOracle, uint8 tokenDecimals, uint8 oracleDecimals
    );
    event GlobalTrialEndsAtUpdated(uint256 trialEndsAt);
    event TopicTrialEndsAtUpdated(bytes32 indexed topicId, uint256 trialEndsAt);
    event TopicPaymentAllowlistUpdated(bytes32 indexed topicId, bool enabled);
    event TopicPaymentTokenUpdated(bytes32 indexed topicId, address indexed payToken, bool allowed);
    event ExpiryUpdated(bytes32 indexed topicId, address indexed user, uint256 oldExpiry, uint256 newExpiry);

    event RamblePairUpdated(address indexed pair);

    event Topup(
        bytes32 indexed topicId,
        address indexed payer,
        address indexed beneficiary,
        address payToken,
        uint256 amountIn,
        uint256 effectiveValueWad,
        uint256 newExpiry
    );

    event PrivilegedCallExecuted(address indexed executor, address indexed target, uint256 value, bool success);
    event PrivilegedWithdrawalExecuted(
        address indexed executor, address indexed asset, address indexed recipient, uint256 amount
    );

    event TopicDeactivated(bytes32 indexed topicId);
    event TopicReactivated(bytes32 indexed topicId);

    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

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

    receive() external payable { }

    function hashTopicKey(
        string calldata topicKey
    ) external pure returns (bytes32) {
        return _hashTopicKey(topicKey);
    }

    function createTopic(
        bytes32 topicId,
        uint256 monthlyPriceWad
    ) external onlyOwner {
        _createTopic(topicId, monthlyPriceWad);
    }

    function createTopicByKey(
        string calldata topicKey,
        uint256 monthlyPriceWad
    ) external onlyOwner {
        bytes32 topicId = _hashTopicKey(topicKey);
        _createTopic(topicId, monthlyPriceWad);
        _registerTopicKey(topicId, topicKey);
    }

    function setTopicKey(
        bytes32 topicId,
        string calldata topicKey
    ) external onlyOwner {
        _requireTopic(topicId);
        _registerTopicKey(topicId, topicKey);
    }

    function setTopicPrice(
        bytes32 topicId,
        uint256 newMonthlyPriceWad
    ) external onlyOwner {
        Topic storage topic = _requireTopic(topicId);
        topic.monthlyPriceWad = newMonthlyPriceWad;

        emit TopicPriceUpdated(topicId, newMonthlyPriceWad);
    }

    function setTopicAnnualPrice(
        bytes32 topicId,
        uint256 newAnnualPriceWad
    ) external onlyOwner {
        _requireTopic(topicId);
        _annualPriceWadByTopic[topicId] = newAnnualPriceWad;

        emit TopicAnnualPriceUpdated(topicId, newAnnualPriceWad);
    }

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

    function isTopicActive(
        bytes32 topicId
    ) external view returns (bool) {
        return _topics[topicId].exists && !_topicDeactivated[topicId];
    }

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

    function setRambleDiscountBps(
        uint16 newDiscountBps
    ) external onlyOwner {
        _setRambleDiscountBps(newDiscountBps);
    }

    function setExecutor(
        address executor_
    ) external onlyOwner {
        _setExecutor(executor_);
    }

    function setOracleConfig(
        address bnbUsdOracle_,
        uint256 maxOracleDelay_
    ) external onlyOwner {
        _setOracleConfig(bnbUsdOracle_, maxOracleDelay_);
    }

    function setStableToken(
        address token,
        bool enabled
    ) external onlyOwner {
        (uint8 tokenDecimals,) = _setPaymentToken(token, enabled, address(0), false);
        emit StableTokenUpdated(token, enabled, tokenDecimals);
    }

    function setPaymentToken(
        address token,
        bool enabled,
        address usdOracle
    ) external onlyOwner {
        _setPaymentToken(token, enabled, usdOracle, true);
    }

    function setRamblePair(
        address rambleWbnbPair_
    ) external onlyOwner {
        _setRamblePair(rambleWbnbPair_);
    }

    function setGlobalTrialEndsAt(
        uint256 trialEndsAt
    ) external onlyOwner {
        _globalTrialEndsAt = trialEndsAt;
        emit GlobalTrialEndsAtUpdated(trialEndsAt);
    }

    function setTopicTrialEndsAt(
        bytes32 topicId,
        uint256 trialEndsAt
    ) external onlyOwner {
        _requireTopic(topicId);
        _topicTrialEndsAt[topicId] = trialEndsAt;
        emit TopicTrialEndsAtUpdated(topicId, trialEndsAt);
    }

    function setTopicPaymentAllowlistEnabled(
        bytes32 topicId,
        bool enabled
    ) external onlyOwner {
        _requireTopic(topicId);
        _topicPaymentAllowlistEnabled[topicId] = enabled;
        emit TopicPaymentAllowlistUpdated(topicId, enabled);
    }

    function setTopicPaymentToken(
        bytes32 topicId,
        address payToken,
        bool allowed
    ) external onlyOwner {
        _requireTopic(topicId);
        _topicPaymentTokenAllowed[topicId][payToken] = allowed;
        emit TopicPaymentTokenUpdated(topicId, payToken, allowed);
    }

    function setExpiry(
        bytes32 topicId,
        address user,
        uint256 newExpiry
    ) external onlyOwner {
        _setExpiry(topicId, user, newExpiry);
    }

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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function topup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        address beneficiary
    ) external payable whenNotPaused nonReentrant returns (uint256 newExpiry) {
        return _topup(topicId, payToken, amountIn, beneficiary, 0, 0);
    }

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

    function topupAnnual(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        address beneficiary,
        uint256 minEffectiveValueWad,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256 newExpiry) {
        return _topupAnnual(topicId, payToken, amountIn, beneficiary, minEffectiveValueWad, deadline);
    }

    function _topup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        address beneficiary,
        uint256 minEffectiveValueWad,
        uint256 deadline
    ) internal returns (uint256 newExpiry) {
        Topic storage topic = _requireActiveTopic(topicId);
        return _topupForBillingCycle(
            topicId, payToken, amountIn, beneficiary, minEffectiveValueWad, deadline, ONE_MONTH, topic.monthlyPriceWad
        );
    }

    function _topupAnnual(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        address beneficiary,
        uint256 minEffectiveValueWad,
        uint256 deadline
    ) internal returns (uint256 newExpiry) {
        Topic storage topic = _requireActiveTopic(topicId);
        uint256 annualPriceWad = _resolveAnnualPriceWad(topic.monthlyPriceWad, _annualPriceWadByTopic[topicId]);
        return _topupForBillingCycle(
            topicId, payToken, amountIn, beneficiary, minEffectiveValueWad, deadline, ONE_YEAR, annualPriceWad
        );
    }

    function _topupForBillingCycle(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        address beneficiary,
        uint256 minEffectiveValueWad,
        uint256 deadline,
        uint256 billingCycleSeconds,
        uint256 billingCyclePriceWad
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

        if (_whitelistByTopicUser[topicId][beneficiary]) {
            revert WhitelistedUserNoPaymentRequired(topicId, beneficiary);
        }
        if (_isTrialActive(topicId)) {
            revert TrialPeriodNoPaymentRequired(topicId, _getEffectiveTrialEndsAt(topicId));
        }
        if (billingCyclePriceWad == 0) {
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

        if (calc.effectiveValueWad < billingCyclePriceWad) {
            revert MinimumPaymentNotMet(calc.effectiveValueWad, billingCyclePriceWad);
        }

        calc.oldExpiry = _expiryByTopicUser[topicId][beneficiary];
        (calc.newExpiry,) = TopicAccessPolicyLib.computeNewExpiry(
            calc.oldExpiry, block.timestamp, calc.effectiveValueWad, billingCycleSeconds, billingCyclePriceWad
        );
        _expiryByTopicUser[topicId][beneficiary] = calc.newExpiry;
        newExpiry = calc.newExpiry;

        emit Topup(topicId, msg.sender, beneficiary, payToken, amountIn, calc.effectiveValueWad, calc.newExpiry);
    }

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

    function getExpiry(
        bytes32 topicId,
        address user
    ) external view returns (uint256) {
        return _expiryByTopicUser[topicId][user];
    }

    function isWhitelisted(
        bytes32 topicId,
        address user
    ) external view returns (bool) {
        return _whitelistByTopicUser[topicId][user];
    }

    function hasAccess(
        bytes32 topicId,
        address user
    ) public view returns (bool) {
        Topic storage topic = _topics[topicId];
        return TopicAccessPolicyLib.hasAccess(
            topic.exists && !_topicDeactivated[topicId],
            _whitelistByTopicUser[topicId][user],
            _getEffectiveTrialEndsAt(topicId),
            topic.monthlyPriceWad,
            _expiryByTopicUser[topicId][user],
            block.timestamp
        );
    }

    function topicExists(
        bytes32 topicId
    ) external view returns (bool) {
        return _topics[topicId].exists;
    }

    function getTopicPriceWad(
        bytes32 topicId
    ) external view returns (uint256) {
        return _requireTopic(topicId).monthlyPriceWad;
    }

    function getTopicAnnualPriceWad(
        bytes32 topicId
    ) external view returns (uint256) {
        Topic storage topic = _requireTopic(topicId);
        return _resolveAnnualPriceWad(topic.monthlyPriceWad, _annualPriceWadByTopic[topicId]);
    }

    function getRambleDiscountBps() external view returns (uint16) {
        return _rambleDiscountBps;
    }

    function getTopicCount() external view returns (uint256) {
        return _topicIds.length;
    }

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

    function getTopicKey(
        bytes32 topicId
    ) external view returns (string memory topicKey) {
        _requireTopic(topicId);
        topicKey = _topicKeyById[topicId];
    }

    function getExecutor() external view returns (address executor) {
        return _executor;
    }

    function getPaymentTokenConfig(
        address token
    ) external view returns (bool enabled, uint8 tokenDecimals, address usdOracle, uint8 oracleDecimals) {
        PaymentTokenConfig memory config = _getPaymentTokenConfig(token);
        enabled = config.enabled;
        tokenDecimals = config.tokenDecimals;
        usdOracle = config.usdOracle;
        oracleDecimals = config.oracleDecimals;
    }

    function getStableTokenConfig(
        address token
    ) external view returns (bool enabled, uint8 decimals) {
        PaymentTokenConfig memory config = _getPaymentTokenConfig(token);
        enabled = config.enabled;
        decimals = config.tokenDecimals;
    }

    function getLegacyStableTokens() external view returns (address legacyUsdc, address legacyUsdt) {
        // Exposed for upgrade migration scripts; values come from deprecated V1 storage fields.
        return (_usdc, _usdt);
    }

    function getOracleConfig() external view returns (address bnbUsdOracle, uint256 maxOracleDelay) {
        return (_bnbUsdOracle, _maxOracleDelay);
    }

    function getGlobalTrialEndsAt() external view returns (uint256) {
        return _globalTrialEndsAt;
    }

    function getTopicTrialEndsAt(
        bytes32 topicId
    ) external view returns (uint256) {
        _requireTopic(topicId);
        return _topicTrialEndsAt[topicId];
    }

    function getEffectiveTrialEndsAt(
        bytes32 topicId
    ) external view returns (uint256) {
        _requireTopic(topicId);
        return _getEffectiveTrialEndsAt(topicId);
    }

    function getTopicPaymentAllowlistEnabled(
        bytes32 topicId
    ) external view returns (bool) {
        _requireTopic(topicId);
        return _topicPaymentAllowlistEnabled[topicId];
    }

    function isTopicPaymentTokenAllowed(
        bytes32 topicId,
        address payToken
    ) external view returns (bool) {
        _requireTopic(topicId);
        return _isTopicPaymentTokenAllowed(topicId, payToken);
    }

    function getRamblePair() external view returns (address) {
        return _rambleWbnbPair;
    }

    function quoteMinBnbForOneMonth(
        bytes32 topicId
    ) external view returns (uint256 minBnbWei) {
        Topic storage topic = _requireActiveTopic(topicId);
        minBnbWei = _quoteMinTokenForValueWad(topicId, address(0), topic.monthlyPriceWad);
    }

    function quoteMinRambleForOneMonth(
        bytes32 topicId
    ) external view returns (uint256 minRambleAmount) {
        Topic storage topic = _requireActiveTopic(topicId);
        minRambleAmount = _quoteMinTokenForValueWad(topicId, RAMBLE_TOKEN, topic.monthlyPriceWad);
    }

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

    function quoteMinTokenForOneMonth(
        bytes32 topicId,
        address payToken
    ) external view returns (uint256 minTokenAmount) {
        Topic storage topic = _requireActiveTopic(topicId);
        minTokenAmount = _quoteMinTokenForValueWad(topicId, payToken, topic.monthlyPriceWad);
    }

    function quoteMinBnbForAnnual(
        bytes32 topicId
    ) external view returns (uint256 minBnbWei) {
        Topic storage topic = _requireActiveTopic(topicId);
        minBnbWei = _quoteMinTokenForValueWad(
            topicId, address(0), _resolveAnnualPriceWad(topic.monthlyPriceWad, _annualPriceWadByTopic[topicId])
        );
    }

    function quoteMinRambleForAnnual(
        bytes32 topicId
    ) external view returns (uint256 minRambleAmount) {
        Topic storage topic = _requireActiveTopic(topicId);
        minRambleAmount = _quoteMinTokenForValueWad(
            topicId, RAMBLE_TOKEN, _resolveAnnualPriceWad(topic.monthlyPriceWad, _annualPriceWadByTopic[topicId])
        );
    }

    function quoteMinTokenForAnnual(
        bytes32 topicId,
        address payToken
    ) external view returns (uint256 minTokenAmount) {
        Topic storage topic = _requireActiveTopic(topicId);
        minTokenAmount = _quoteMinTokenForValueWad(
            topicId, payToken, _resolveAnnualPriceWad(topic.monthlyPriceWad, _annualPriceWadByTopic[topicId])
        );
    }

    function previewTopup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn
    ) external view returns (uint256 rawValueWad, uint256 effectiveValueWad, uint256 secondsAdded) {
        Topic storage topic = _requireActiveTopic(topicId);
        return _previewTopupForBillingCycle(topicId, payToken, amountIn, ONE_MONTH, topic.monthlyPriceWad);
    }

    function previewAnnualTopup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn
    ) external view returns (uint256 rawValueWad, uint256 effectiveValueWad, uint256 secondsAdded) {
        Topic storage topic = _requireActiveTopic(topicId);
        return _previewTopupForBillingCycle(
            topicId,
            payToken,
            amountIn,
            ONE_YEAR,
            _resolveAnnualPriceWad(topic.monthlyPriceWad, _annualPriceWadByTopic[topicId])
        );
    }

    function _previewTopupForBillingCycle(
        bytes32 topicId,
        address payToken,
        uint256 amountIn,
        uint256 billingCycleSeconds,
        uint256 billingCyclePriceWad
    ) internal view returns (uint256 rawValueWad, uint256 effectiveValueWad, uint256 secondsAdded) {
        if (_isNoPaymentRequired(topicId, billingCyclePriceWad) || amountIn == 0) {
            return (0, 0, 0);
        }
        _requireTopicPaymentTokenAllowed(topicId, payToken);

        (rawValueWad, effectiveValueWad) = _previewPaymentValueWad(payToken, amountIn);
        (, secondsAdded) =
            TopicAccessPolicyLib.computeNewExpiry(0, 0, effectiveValueWad, billingCycleSeconds, billingCyclePriceWad);
    }

    function _quoteMinTokenForValueWad(
        bytes32 topicId,
        address payToken,
        uint256 targetValueWad
    ) internal view returns (uint256 minTokenAmount) {
        if (_isNoPaymentRequired(topicId, targetValueWad)) {
            return 0;
        }
        _requireTopicPaymentTokenAllowed(topicId, payToken);

        if (payToken == address(0)) {
            (uint256 bnbUsdPrice, uint8 oracleDecimals) = _getBnbPriceChecked();
            return Math.mulDiv(targetValueWad, WadScaleLib.pow10(oracleDecimals), bnbUsdPrice, Math.Rounding.Ceil);
        }
        if (payToken == RAMBLE_TOKEN) {
            _requireRamblePaymentSupported();
            return _quoteMinRambleForValueWad(targetValueWad);
        }
        if (!_paymentTokenEnabled[payToken]) {
            revert UnsupportedPayToken(payToken);
        }

        minTokenAmount = _quoteMinConfiguredTokenAmount(payToken, targetValueWad);
    }

    function _setRambleDiscountBps(
        uint16 newDiscountBps
    ) internal {
        if (newDiscountBps == 0 || newDiscountBps > uint16(BPS_BASE)) {
            revert InvalidDiscountBps(newDiscountBps);
        }

        _rambleDiscountBps = newDiscountBps;

        emit RambleDiscountUpdated(newDiscountBps);
    }

    function _setExecutor(
        address executor_
    ) internal {
        _executor = executor_;

        emit ExecutorUpdated(executor_);
    }

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

    function _validateRamblePair(
        address rambleWbnbPair_
    ) internal {
        if (rambleWbnbPair_.code.length == 0) {
            revert RamblePairNotConfigured(rambleWbnbPair_);
        }

        // Fail fast on misconfigured pair instead of deferring failure to topup/quote.
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

        // Ensure the pinned wrapped native token still exposes the unwrap entrypoint.
        (bool canWithdraw,) = wrappedNative.call(abi.encodeWithSignature("withdraw(uint256)", 0));
        if (!canWithdraw) {
            revert WrappedNativeWithdrawFailed(wrappedNative);
        }
    }

    function _readTokenDecimals(
        address token
    ) internal view returns (uint8 decimals_) {
        decimals_ = IERC20Metadata(token).decimals();
    }

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

    function _hashTopicKey(
        string memory topicKey
    ) internal pure returns (bytes32) {
        if (bytes(topicKey).length == 0) {
            revert EmptyTopicKey();
        }

        return keccak256(bytes(topicKey));
    }

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

    function _resolveAnnualPriceWad(
        uint256 monthlyPriceWad,
        uint256 configuredAnnualPriceWad
    ) internal pure returns (uint256) {
        if (monthlyPriceWad == 0) {
            return 0;
        }
        return configuredAnnualPriceWad == 0 ? monthlyPriceWad * MONTHS_PER_YEAR : configuredAnnualPriceWad;
    }

    function _previewPaymentValueWad(
        address payToken,
        uint256 amountIn
    ) internal view returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        // Native BNB and oracle-priced tokens use 1:1 effective value; RAMBLE applies discount-adjusted value.
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

    function _quoteStableValueWad(
        uint256 amountIn,
        uint8 tokenDecimals
    ) internal pure returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        rawValueWad = WadScaleLib.toWad(amountIn, tokenDecimals);
        effectiveValueWad = rawValueWad;
    }

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

    function _quoteBnbValueWad(
        uint256 bnbAmountWei
    ) internal view returns (uint256) {
        (uint256 bnbUsdPrice, uint8 oracleDecimals) = _getBnbPriceChecked();
        uint256 oracleScale = WadScaleLib.pow10(oracleDecimals);

        return Math.mulDiv(bnbAmountWei, bnbUsdPrice, oracleScale);
    }

    function _quoteRambleValueWad(
        uint256 rambleAmount
    ) internal view returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        _requireRamblePaymentSupported();
        // RAMBLE amount is converted to expected WBNB out (AMM curve), then priced by BNB/USD oracle.
        uint256 wbnbOut = _estimateWbnbOutFromRamble(rambleAmount);
        rawValueWad = _quoteBnbValueWad(wbnbOut);
        // Discount bps means user pays only part of USD value: e.g. 9000 -> 90%.
        effectiveValueWad = Math.mulDiv(rawValueWad, BPS_BASE, _rambleDiscountBps);
    }

    function _estimateWbnbOutFromRamble(
        uint256 rambleAmount
    ) internal view returns (uint256 wbnbOut) {
        IPancakePairV2 pair = _getConfiguredRamblePair();
        (,, uint256 reserveIn, uint256 reserveOut) = _getRamblePairState(pair);
        wbnbOut =
            RamblePricingLib.getV2AmountOut(rambleAmount, reserveIn, reserveOut, V2_FEE_NUMERATOR, V2_FEE_DENOMINATOR);
    }

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

    function _getConfiguredRamblePair() internal view returns (IPancakePairV2 pair) {
        _requireRamblePaymentSupported();
        address pairAddress = _rambleWbnbPair;
        if (pairAddress == address(0) || pairAddress.code.length == 0) {
            revert RamblePairNotConfigured(pairAddress);
        }
        pair = IPancakePairV2(pairAddress);
    }

    function _getBnbPriceChecked() internal view returns (uint256 bnbUsdPrice, uint8 oracleDecimals) {
        return _readOraclePriceChecked(_bnbUsdOracle, _maxOracleDelay);
    }

    function _getPaymentTokenConfig(
        address token
    ) internal view returns (PaymentTokenConfig memory config) {
        config.enabled = _paymentTokenEnabled[token];
        config.tokenDecimals = _paymentTokenDecimals[token];
        config.usdOracle = _paymentTokenOracle[token];
        config.oracleDecimals = _paymentTokenOracleDecimals[token];
    }

    function _storePaymentTokenConfig(
        address token,
        PaymentTokenConfig memory config
    ) internal {
        _paymentTokenEnabled[token] = config.enabled;
        _paymentTokenDecimals[token] = config.tokenDecimals;
        _paymentTokenOracle[token] = config.usdOracle;
        _paymentTokenOracleDecimals[token] = config.oracleDecimals;
    }

    function _isNoPaymentRequired(
        bytes32 topicId,
        uint256 monthlyPriceWad
    ) internal view returns (bool) {
        return
            TopicAccessPolicyLib.isNoPaymentRequired(
                monthlyPriceWad, _getEffectiveTrialEndsAt(topicId), block.timestamp
            );
    }

    function _isTopicPaymentTokenAllowed(
        bytes32 topicId,
        address payToken
    ) internal view returns (bool) {
        return TopicAccessPolicyLib.isTopicPaymentTokenAllowed(
            _topicPaymentAllowlistEnabled[topicId], _topicPaymentTokenAllowed[topicId][payToken]
        );
    }

    function _requireTopicPaymentTokenAllowed(
        bytes32 topicId,
        address payToken
    ) internal view {
        if (!_isTopicPaymentTokenAllowed(topicId, payToken)) {
            revert PayTokenNotAllowedForTopic(topicId, payToken);
        }
    }

    function _isTrialActive(
        bytes32 topicId
    ) internal view returns (bool) {
        return
            TopicAccessPolicyLib.effectiveTrialEndsAt(_globalTrialEndsAt, _topicTrialEndsAt[topicId]) > block.timestamp;
    }

    function _isBscChain() internal view returns (bool) {
        return block.chainid == BSC_CHAIN_ID;
    }

    function _requireRamblePaymentSupported() internal view {
        if (!_isBscChain()) {
            revert RambleOnlySupportedOnBsc(block.chainid);
        }
    }

    function _getEffectiveTrialEndsAt(
        bytes32 topicId
    ) internal view returns (uint256) {
        return TopicAccessPolicyLib.effectiveTrialEndsAt(_globalTrialEndsAt, _topicTrialEndsAt[topicId]);
    }

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

    function _requireTopic(
        bytes32 topicId
    ) internal view returns (Topic storage topic) {
        topic = _topics[topicId];
        if (!topic.exists) {
            revert TopicNotFound(topicId);
        }
    }

    function _requireActiveTopic(
        bytes32 topicId
    ) internal view returns (Topic storage topic) {
        topic = _requireTopic(topicId);
        if (_topicDeactivated[topicId]) {
            revert TopicIsDeactivated(topicId);
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyOwner {
        if (newImplementation == address(0)) {
            revert ZeroAddress();
        }
    }

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

    modifier onlyPrivilegedCaller() {
        if (msg.sender != owner() && msg.sender != _executor) {
            revert NotExecutor(msg.sender);
        }
        _;
    }
}
