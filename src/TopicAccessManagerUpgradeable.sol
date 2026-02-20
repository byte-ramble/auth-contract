// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IAggregatorV3.sol";
import "./interfaces/IPancakePairV2.sol";
import "./libraries/WadScaleLib.sol";

contract TopicAccessManagerUpgradeable is Initializable, UUPSUpgradeable, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Topic {
        bool exists;
        uint256 monthlyPriceWad;
    }

    struct TopupCalc {
        uint256 effectiveValueWad;
        uint256 oldExpiry;
        uint256 newExpiry;
    }

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS_BASE = 10_000;
    uint256 public constant ONE_MONTH = 30 days;

    address public constant RAMBLE_TOKEN = 0x1A8C391f6c603894108fcE14A52E9Bf804c67777;
    address public constant DEFAULT_RAMBLE_WBNB_PAIR = 0x185e706a55d04815e7e10b506A5a4d8d1153aeAD;
    uint16 public constant DEFAULT_RAMBLE_DISCOUNT_BPS = 9500;

    uint256 private constant V2_FEE_NUMERATOR = 9975;
    uint256 private constant V2_FEE_DENOMINATOR = 10_000;
    uint256 private constant MAX_QUOTE_SEARCH_STEPS = 64;

    mapping(bytes32 => Topic) private _topics;
    mapping(bytes32 => mapping(address => uint256)) private _expiryByTopicUser;
    mapping(bytes32 => mapping(address => bool)) private _whitelistByTopicUser;

    uint16 private _rambleDiscountBps;

    address private _executorA;
    address private _executorB;

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

    mapping(address => bool) private _stableTokenEnabled;
    mapping(address => uint8) private _stableTokenDecimals;

    uint256[38] private __gap;

    error ZeroAddress();
    error EmptyTopicKey();
    error InvalidTopicId();
    error TopicNotFound(bytes32 topicId);
    error TopicAlreadyExists(bytes32 topicId);
    error AmountZero();
    error UnsupportedPayToken(address payToken);
    error NativeValueMismatch(uint256 msgValue, uint256 amountIn);
    error UnexpectedNativeValue(uint256 msgValue);
    error FreeTopicNoPaymentRequired(bytes32 topicId);
    error WhitelistedUserNoPaymentRequired(bytes32 topicId, address user);
    error MinimumPaymentNotMet(uint256 effectiveValueWad, uint256 monthlyPriceWad);
    error InvalidDiscountBps(uint16 discountBps);
    error InvalidOracleConfig();
    error NotExecutor(address caller);
    error InvalidPrivilegedTarget(address target);
    error InvalidStableToken(address token);
    error OraclePriceInvalid();
    error OraclePriceStale(uint256 updatedAt, uint256 nowTimestamp, uint256 maxOracleDelay);
    error OracleRoundInvalid(uint80 roundId, uint80 answeredInRound);
    error PairTokenMismatch(address token0, address token1, address ramble);
    error RamblePairNotConfigured(address pair);
    error PairLiquidityTooLow();
    error WrappedNativeWithdrawFailed(address wrappedNative);
    error QuoteUnavailable();

    event TopicCreated(bytes32 indexed topicId, uint256 monthlyPriceWad);
    event TopicPriceUpdated(bytes32 indexed topicId, uint256 newPriceWad);
    event WhitelistUpdated(bytes32 indexed topicId, address indexed user, bool isWhitelisted);

    event RambleDiscountUpdated(uint16 newBps);

    event ExecutorsUpdated(address indexed executorA, address indexed executorB);

    event OracleConfigUpdated(address indexed oracle, uint256 maxOracleDelay);

    event StableTokenUpdated(address indexed token, bool enabled, uint8 decimals);

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

    constructor() {
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
    }

    function setTopicPrice(
        bytes32 topicId,
        uint256 newMonthlyPriceWad
    ) external onlyOwner {
        Topic storage topic = _requireTopic(topicId);
        topic.monthlyPriceWad = newMonthlyPriceWad;

        emit TopicPriceUpdated(topicId, newMonthlyPriceWad);
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

    function setExecutors(
        address executorA_,
        address executorB_
    ) external onlyOwner {
        _setExecutors(executorA_, executorB_);
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
        _setStableToken(token, enabled);
    }

    function setRamblePair(
        address rambleWbnbPair_
    ) external onlyOwner {
        _setRamblePair(rambleWbnbPair_);
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
        if (amountIn == 0) {
            revert AmountZero();
        }
        if (beneficiary == address(0)) {
            revert ZeroAddress();
        }

        Topic storage topic = _requireTopic(topicId);
        if (topic.monthlyPriceWad == 0) {
            revert FreeTopicNoPaymentRequired(topicId);
        }
        if (_whitelistByTopicUser[topicId][beneficiary]) {
            revert WhitelistedUserNoPaymentRequired(topicId, beneficiary);
        }

        TopupCalc memory calc;

        if (payToken == address(0)) {
            if (msg.value != amountIn) {
                revert NativeValueMismatch(msg.value, amountIn);
            }
            calc.effectiveValueWad = _quoteBnbValueWad(amountIn);
        } else if (payToken == RAMBLE_TOKEN) {
            if (msg.value != 0) {
                revert UnexpectedNativeValue(msg.value);
            }
            IERC20(RAMBLE_TOKEN).safeTransferFrom(msg.sender, address(this), amountIn);
            calc.effectiveValueWad = _swapRambleToBnb(amountIn);
        } else {
            if (msg.value != 0) {
                revert UnexpectedNativeValue(msg.value);
            }
            (, calc.effectiveValueWad) = _previewPaymentValueWad(payToken, amountIn);
            if (calc.effectiveValueWad < topic.monthlyPriceWad) {
                revert MinimumPaymentNotMet(calc.effectiveValueWad, topic.monthlyPriceWad);
            }
            IERC20(payToken).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        if (calc.effectiveValueWad < topic.monthlyPriceWad) {
            revert MinimumPaymentNotMet(calc.effectiveValueWad, topic.monthlyPriceWad);
        }

        calc.oldExpiry = _expiryByTopicUser[topicId][beneficiary];
        uint256 secondsAdded = Math.mulDiv(calc.effectiveValueWad, ONE_MONTH, topic.monthlyPriceWad);
        calc.newExpiry = Math.max(calc.oldExpiry, block.timestamp) + secondsAdded;
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

        (success, returnData) = target.call{ value: value }(data);

        emit PrivilegedCallExecuted(msg.sender, target, value, success);
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
        if (!topic.exists) {
            return false;
        }
        if (_whitelistByTopicUser[topicId][user]) {
            return true;
        }
        if (topic.monthlyPriceWad == 0) {
            return true;
        }
        return _expiryByTopicUser[topicId][user] >= block.timestamp;
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

    function getRambleDiscountBps() external view returns (uint16) {
        return _rambleDiscountBps;
    }

    function getExecutors() external view returns (address executorA, address executorB) {
        return (_executorA, _executorB);
    }

    function getStableTokenConfig(
        address token
    ) external view returns (bool enabled, uint8 decimals) {
        enabled = _stableTokenEnabled[token];
        decimals = _stableTokenDecimals[token];
    }

    function getLegacyStableTokens() external view returns (address legacyUsdc, address legacyUsdt) {
        // Exposed for upgrade migration scripts; values come from deprecated V1 storage fields.
        return (_usdc, _usdt);
    }

    function getOracleConfig() external view returns (address bnbUsdOracle, uint256 maxOracleDelay) {
        return (_bnbUsdOracle, _maxOracleDelay);
    }

    function getRamblePair() external view returns (address) {
        return _rambleWbnbPair;
    }

    function quoteMinBnbForOneMonth(
        bytes32 topicId
    ) external view returns (uint256 minBnbWei) {
        Topic storage topic = _requireTopic(topicId);
        if (topic.monthlyPriceWad == 0) {
            return 0;
        }

        (uint256 bnbUsdPrice, uint8 oracleDecimals) = _getBnbPriceChecked();
        uint256 oracleScale = WadScaleLib.pow10(oracleDecimals);

        minBnbWei = Math.mulDiv(topic.monthlyPriceWad, oracleScale, bnbUsdPrice, Math.Rounding.Up);
    }

    function quoteMinRambleForOneMonth(
        bytes32 topicId
    ) external view returns (uint256 minRambleAmount) {
        Topic storage topic = _requireTopic(topicId);
        uint256 monthlyPriceWad = topic.monthlyPriceWad;
        if (monthlyPriceWad == 0) {
            return 0;
        }

        uint256 high = 1;
        uint256 effectiveValueWad;
        bool foundHigh;

        for (uint256 i = 0; i < MAX_QUOTE_SEARCH_STEPS; ++i) {
            (, effectiveValueWad) = _quoteRambleValueWad(high);
            if (effectiveValueWad >= monthlyPriceWad) {
                foundHigh = true;
                break;
            }

            if (high > type(uint256).max / 2) {
                revert QuoteUnavailable();
            }

            high *= 2;
        }

        if (!foundHigh) {
            (, effectiveValueWad) = _quoteRambleValueWad(high);
            if (effectiveValueWad < monthlyPriceWad) {
                revert QuoteUnavailable();
            }
        }

        uint256 low = 0;
        for (uint256 i = 0; i < MAX_QUOTE_SEARCH_STEPS; ++i) {
            if (low + 1 >= high) {
                break;
            }

            uint256 mid = low + ((high - low) / 2);
            (, effectiveValueWad) = _quoteRambleValueWad(mid);

            if (effectiveValueWad >= monthlyPriceWad) {
                high = mid;
            } else {
                low = mid;
            }
        }

        minRambleAmount = high;
    }

    function previewTopup(
        bytes32 topicId,
        address payToken,
        uint256 amountIn
    ) external view returns (uint256 rawValueWad, uint256 effectiveValueWad, uint256 secondsAdded) {
        Topic storage topic = _requireTopic(topicId);

        if (topic.monthlyPriceWad == 0 || amountIn == 0) {
            return (0, 0, 0);
        }

        (rawValueWad, effectiveValueWad) = _previewPaymentValueWad(payToken, amountIn);
        secondsAdded = Math.mulDiv(effectiveValueWad, ONE_MONTH, topic.monthlyPriceWad);
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

    function _setExecutors(
        address executorA_,
        address executorB_
    ) internal {
        _executorA = executorA_;
        _executorB = executorB_;

        emit ExecutorsUpdated(executorA_, executorB_);
    }

    function _setOracleConfig(
        address bnbUsdOracle_,
        uint256 maxOracleDelay_
    ) internal {
        if (bnbUsdOracle_ == address(0) || maxOracleDelay_ == 0) {
            revert InvalidOracleConfig();
        }

        _bnbUsdOracle = bnbUsdOracle_;
        _maxOracleDelay = maxOracleDelay_;

        emit OracleConfigUpdated(bnbUsdOracle_, maxOracleDelay_);
    }

    function _setStableToken(
        address token,
        bool enabled
    ) internal {
        if (token == address(0)) {
            revert ZeroAddress();
        }
        if (token == RAMBLE_TOKEN) {
            revert InvalidStableToken(token);
        }

        uint8 decimals = _stableTokenDecimals[token];
        if (enabled) {
            if (token.code.length == 0) {
                revert InvalidStableToken(token);
            }
            decimals = _readTokenDecimals(token);
            WadScaleLib.validateDecimals(decimals);
            _stableTokenDecimals[token] = decimals;
        }
        _stableTokenEnabled[token] = enabled;

        emit StableTokenUpdated(token, enabled, decimals);
    }

    function _setDefaultRamblePair() internal {
        _rambleWbnbPair = DEFAULT_RAMBLE_WBNB_PAIR;
        emit RamblePairUpdated(DEFAULT_RAMBLE_WBNB_PAIR);

        if (DEFAULT_RAMBLE_WBNB_PAIR.code.length > 0) {
            _validateRamblePair(DEFAULT_RAMBLE_WBNB_PAIR);
        }
    }

    function _setRamblePair(
        address rambleWbnbPair_
    ) internal {
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

        // Ensure the counter token can be unwrapped into native BNB.
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

    function _previewPaymentValueWad(
        address payToken,
        uint256 amountIn
    ) internal view returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        // Native BNB and stablecoins use 1:1 effective value; RAMBLE applies discount-adjusted value.
        if (payToken == address(0)) {
            rawValueWad = _quoteBnbValueWad(amountIn);
            effectiveValueWad = rawValueWad;
            return (rawValueWad, effectiveValueWad);
        }

        if (payToken == RAMBLE_TOKEN) {
            return _quoteRambleValueWad(amountIn);
        }

        if (_stableTokenEnabled[payToken]) {
            return _quoteStableValueWad(amountIn, _stableTokenDecimals[payToken]);
        }

        revert UnsupportedPayToken(payToken);
    }

    function _quoteStableValueWad(
        uint256 amountIn,
        uint8 tokenDecimals
    ) internal pure returns (uint256 rawValueWad, uint256 effectiveValueWad) {
        rawValueWad = WadScaleLib.toWad(amountIn, tokenDecimals);
        effectiveValueWad = rawValueWad;
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
        // RAMBLE amount is converted to expected WBNB out (AMM curve), then priced by BNB/USD oracle.
        uint256 wbnbOut = _estimateWbnbOutFromRamble(rambleAmount);
        rawValueWad = _quoteBnbValueWad(wbnbOut);
        // Discount bps means user pays only part of USD value: e.g. 9500 -> 95%.
        effectiveValueWad = Math.mulDiv(rawValueWad, BPS_BASE, _rambleDiscountBps);
    }

    function _estimateWbnbOutFromRamble(
        uint256 rambleAmount
    ) internal view returns (uint256 wbnbOut) {
        IPancakePairV2 pair = _getConfiguredRamblePair();
        (,, uint256 reserveIn, uint256 reserveOut) = _getRamblePairState(pair);
        wbnbOut = _getV2AmountOut(rambleAmount, reserveIn, reserveOut);
    }

    function _swapRambleToBnb(
        uint256 rambleAmount
    ) internal returns (uint256 effectiveValueWad) {
        IPancakePairV2 pair = _getConfiguredRamblePair();
        (bool rambleIsToken0, address wrappedNative, uint256 reserveIn, uint256 reserveOut) = _getRamblePairState(pair);

        uint256 pairRambleBalanceBefore = IERC20(RAMBLE_TOKEN).balanceOf(address(pair));
        IERC20(RAMBLE_TOKEN).safeTransfer(address(pair), rambleAmount);
        uint256 amountInActual = IERC20(RAMBLE_TOKEN).balanceOf(address(pair)) - pairRambleBalanceBefore;

        uint256 expectedWbnbOut = _getV2AmountOut(amountInActual, reserveIn, reserveOut);
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

        (bool ok,) = wrappedNative.call(abi.encodeWithSignature("withdraw(uint256)", wrappedReceived));
        if (!ok) {
            revert WrappedNativeWithdrawFailed(wrappedNative);
        }

        uint256 rawValueWad = _quoteBnbValueWad(wrappedReceived);
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
        address pairAddress = _rambleWbnbPair;
        if (pairAddress == address(0) || pairAddress.code.length == 0) {
            revert RamblePairNotConfigured(pairAddress);
        }
        pair = IPancakePairV2(pairAddress);
    }

    function _getV2AmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256) {
        if (amountIn == 0) {
            return 0;
        }

        uint256 amountInWithFee = amountIn * V2_FEE_NUMERATOR;
        uint256 denominator = (reserveIn * V2_FEE_DENOMINATOR) + amountInWithFee;
        if (denominator == 0) {
            return 0;
        }

        return Math.mulDiv(amountInWithFee, reserveOut, denominator);
    }

    function _getBnbPriceChecked() internal view returns (uint256 bnbUsdPrice, uint8 oracleDecimals) {
        IAggregatorV3 oracle = IAggregatorV3(_bnbUsdOracle);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) {
            revert OraclePriceInvalid();
        }
        if (block.timestamp - updatedAt > _maxOracleDelay) {
            revert OraclePriceStale(updatedAt, block.timestamp, _maxOracleDelay);
        }
        if (answeredInRound < roundId) {
            revert OracleRoundInvalid(roundId, answeredInRound);
        }

        oracleDecimals = oracle.decimals();
        WadScaleLib.validateDecimals(oracleDecimals);

        bnbUsdPrice = uint256(answer);
    }

    function _requireTopic(
        bytes32 topicId
    ) internal view returns (Topic storage topic) {
        topic = _topics[topicId];
        if (!topic.exists) {
            revert TopicNotFound(topicId);
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyOwner {
        if (newImplementation == address(0)) {
            revert ZeroAddress();
        }
    }

    modifier onlyPrivilegedCaller() {
        if (msg.sender != owner() && msg.sender != _executorA && msg.sender != _executorB) {
            revert NotExecutor(msg.sender);
        }
        _;
    }
}
