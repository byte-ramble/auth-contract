// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/TopicAccessFixture.sol";
import "../../src/libraries/WadScaleLib.sol";
import "../../src/mocks/MockFeeOnTransferERC20.sol";
import "../../src/mocks/TestERC1967Proxy.sol";
import "../../src/mocks/MockWBNBUnderpay.sol";

contract TopicAccessManagerUnitTest is TopicAccessFixture {
    function testRambleConstantsAreApplied() external view {
        assertEq(manager.RAMBLE_TOKEN(), address(ramble), "ramble constant mismatch");
        assertEq(manager.BSC_WBNB(), address(wbnb), "wbnb constant mismatch");
        assertEq(manager.BSC_CHAIN_ID(), 56, "bsc chain id constant mismatch");
        assertEq(
            uint256(manager.getRambleDiscountBps()),
            uint256(manager.DEFAULT_RAMBLE_DISCOUNT_BPS()),
            "default ramble discount mismatch"
        );
    }

    function testHashTopicAndCreateByKey() external {
        string memory topicKey = "omniarb.prod.alpha.vip.v1";
        bytes32 expected = _hashTopic(topicKey);

        bytes32 fromContract = manager.hashTopicKey(topicKey);
        assertEq(fromContract, expected, "topic hash mismatch");

        vm.prank(owner);
        manager.createTopicByKey(topicKey, 100e18);

        assertEq(manager.topicExists(expected), true, "topic not created");
        assertEq(manager.getTopicPriceWad(expected), 100e18, "topic price mismatch");
        assertEq(manager.getTopicAnnualPriceWad(expected), 1200e18, "default annual price mismatch");
        assertEq(manager.getTopicCount(), 1, "topic registry count mismatch");

        (bytes32 topicIdAt0, uint256 topicPriceAt0, string memory topicKeyAt0,) = manager.getTopicAt(0);
        assertEq(topicIdAt0, expected, "topic id registry mismatch");
        assertEq(topicPriceAt0, 100e18, "topic price registry mismatch");
        assertEq(keccak256(bytes(topicKeyAt0)), keccak256(bytes(topicKey)), "topic key registry mismatch");
        assertEq(keccak256(bytes(manager.getTopicKey(expected))), keccak256(bytes(topicKey)), "topic key read mismatch");
    }

    function testTopicDeactivationBlocksTopupAndQuotes() external {
        bytes32 topicId = _hashTopic("deactivated.topic");
        _createTopic(topicId, 100e18);

        assertEq(manager.isTopicActive(topicId), true, "topic should start active");

        vm.prank(owner);
        manager.deactivateTopic(topicId);

        assertEq(manager.isTopicActive(topicId), false, "topic should be inactive");
        assertTrue(manager.topicExists(topicId), "topic should still exist");
        assertTrue(manager.hasAccess(topicId, user) == false, "deactivated topic should not grant access");

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.TopicIsDeactivated.selector, topicId));
        manager.quoteMinBnbForOneMonth(topicId);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.TopicIsDeactivated.selector, topicId));
        manager.quoteMinBnbForAnnual(topicId);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.TopicIsDeactivated.selector, topicId));
        manager.previewTopup(topicId, address(usdc), 100e6);
    }

    function testTopicDeactivationBlocksExistingMemberAccess() external {
        bytes32 topicId = _hashTopic("deactivated.member.topic");
        _createTopic(topicId, 100e18);

        vm.prank(owner);
        manager.setExpiry(topicId, user, block.timestamp + 30 days);
        assertEq(manager.hasAccess(topicId, user), true, "member should have access before deactivation");

        vm.prank(owner);
        manager.deactivateTopic(topicId);
        assertEq(manager.hasAccess(topicId, user), false, "deactivated topic should block existing members");
    }

    function testTopicReactivationRestoresFunctionality() external {
        bytes32 topicId = _hashTopic("reactivated.topic");
        _createTopic(topicId, 100e18);

        vm.startPrank(owner);
        manager.deactivateTopic(topicId);
        manager.reactivateTopic(topicId);
        vm.stopPrank();

        assertEq(manager.isTopicActive(topicId), true, "topic should be active after reactivation");

        _approveAndMint(address(usdc), user, 100e6);
        vm.prank(user);
        uint256 newExpiry = manager.topup(topicId, address(usdc), 100e6, user);
        assertEq(newExpiry, block.timestamp + ONE_MONTH, "topup should work after reactivation");
    }

    function testSetTopicKeyBackfillsReadableRegistryForExistingTopic() external {
        bytes32 topicId = _hashTopic("manual.topic.id");
        string memory topicKey = "manual.topic.id";

        _createTopic(topicId, 42e18);
        assertEq(manager.getTopicCount(), 1, "topic registry count mismatch");

        (, uint256 priceBefore, string memory keyBefore,) = manager.getTopicAt(0);
        assertEq(priceBefore, 42e18, "topic price should be indexed");
        assertEq(bytes(keyBefore).length, 0, "topic key should be empty before backfill");

        vm.prank(owner);
        manager.setTopicKey(topicId, topicKey);

        assertEq(
            keccak256(bytes(manager.getTopicKey(topicId))), keccak256(bytes(topicKey)), "topic key should backfill"
        );
    }

    function testGetTopicAtRejectsOutOfBoundsIndex() external {
        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.TopicIndexOutOfBounds.selector, uint256(0), uint256(0))
        );
        manager.getTopicAt(0);
    }

    function testFreeTopicBoundary() external {
        bytes32 topicId = _hashTopic("free.topic");
        _createTopic(topicId, 0);

        assertEq(manager.hasAccess(topicId, user), true, "free topic should grant access");
        assertEq(manager.quoteMinBnbForOneMonth(topicId), 0, "free topic bnb quote should be zero");
        assertEq(manager.quoteMinRambleForOneMonth(topicId), 0, "free topic ramble quote should be zero");
        assertEq(manager.quoteMinBnbForAnnual(topicId), 0, "free topic annual bnb quote should be zero");

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.FreeTopicNoPaymentRequired.selector, topicId)
        );
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.FreeTopicNoPaymentRequired.selector, topicId)
        );
        vm.prank(user);
        manager.topupAnnual{ value: 1 ether }(topicId, address(0), 1 ether, user, 1, block.timestamp);
    }

    function testTopicTrialGrantsAccessAndBlocksPaymentUntilExpiry() external {
        bytes32 topicId = _hashTopic("trial.topic");
        _createTopic(topicId, 100e18);

        uint256 trialEndsAt = block.timestamp + 7 days;

        vm.prank(owner);
        manager.setTopicTrialEndsAt(topicId, trialEndsAt);

        assertEq(manager.hasAccess(topicId, user), true, "trial should grant access");
        assertEq(manager.getEffectiveTrialEndsAt(topicId), trialEndsAt, "trial end mismatch");
        assertEq(manager.quoteMinBnbForOneMonth(topicId), 0, "trial bnb quote should be zero");
        assertEq(manager.quoteMinBnbForAnnual(topicId), 0, "trial annual bnb quote should be zero");
        assertEq(manager.quoteMinTokenForOneMonth(topicId, address(usdc)), 0, "trial token quote should be zero");

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.TrialPeriodNoPaymentRequired.selector, topicId, trialEndsAt
            )
        );
        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.TrialPeriodNoPaymentRequired.selector, topicId, trialEndsAt
            )
        );
        vm.prank(user);
        manager.topupAnnual(topicId, address(usdc), 1200e6, user, 1, block.timestamp);

        vm.warp(trialEndsAt + 1);
        assertEq(manager.hasAccess(topicId, user), false, "trial access should expire");
    }

    function testGlobalTrialAppliesToAllPaidTopics() external {
        bytes32 topicA = _hashTopic("trial.global.a");
        bytes32 topicB = _hashTopic("trial.global.b");
        _createTopic(topicA, 100e18);
        _createTopic(topicB, 50e18);

        uint256 trialEndsAt = block.timestamp + 3 days;
        vm.prank(owner);
        manager.setGlobalTrialEndsAt(trialEndsAt);

        assertEq(manager.hasAccess(topicA, user), true, "global trial should grant access to topicA");
        assertEq(manager.hasAccess(topicB, user2), true, "global trial should grant access to topicB");
        assertEq(manager.getGlobalTrialEndsAt(), trialEndsAt, "global trial end mismatch");
    }

    function testTopicPaymentAllowlistRestrictsRoutesAndAllowsConfiguredToken() external {
        bytes32 topicId = _hashTopic("paid.allowlist.usdc.only");
        _createTopic(topicId, 100e18);

        vm.startPrank(owner);
        manager.setTopicPaymentToken(topicId, address(usdc), true);
        manager.setTopicPaymentAllowlistEnabled(topicId, true);
        vm.stopPrank();

        assertEq(manager.getTopicPaymentAllowlistEnabled(topicId), true, "allowlist should be enabled");
        assertEq(manager.isTopicPaymentTokenAllowed(topicId, address(usdc)), true, "usdc should be allowed");
        assertEq(manager.isTopicPaymentTokenAllowed(topicId, address(0)), false, "bnb should be blocked");

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.PayTokenNotAllowedForTopic.selector, topicId, address(0)
            )
        );
        manager.quoteMinBnbForOneMonth(topicId);

        uint256 minUsdc = manager.quoteMinTokenForOneMonth(topicId, address(usdc));
        assertEq(minUsdc, 100e6, "usdc quote should still work");
        assertEq(manager.quoteMinTokenForAnnual(topicId, address(usdc)), 1200e6, "annual usdc quote should work");

        _approveAndMint(address(usdc), user, minUsdc);
        vm.prank(user);
        uint256 newExpiry = manager.topup(topicId, address(usdc), minUsdc, user);

        assertEq(newExpiry, block.timestamp + ONE_MONTH, "allowed token should top up");
    }

    function testSetTopicAnnualPriceAndAnnualTopup() external {
        bytes32 topicId = _hashTopic("opland.membership");
        _createTopic(topicId, 49e18);

        vm.prank(owner);
        manager.setTopicAnnualPrice(topicId, 499e18);

        assertEq(manager.getTopicPriceWad(topicId), 49e18, "monthly price mismatch");
        assertEq(manager.getTopicAnnualPriceWad(topicId), 499e18, "annual price mismatch");

        uint256 minUsdc = manager.quoteMinTokenForAnnual(topicId, address(usdc));
        assertEq(minUsdc, 499e6, "annual usdc quote mismatch");

        (, uint256 effectiveValueWad, uint256 secondsAdded) =
            manager.previewAnnualTopup(topicId, address(usdc), minUsdc);
        assertEq(effectiveValueWad, 499e18, "annual effective value mismatch");
        assertEq(secondsAdded, manager.ONE_YEAR(), "annual preview seconds mismatch");

        _approveAndMint(address(usdc), user, minUsdc);
        uint256 t0 = block.timestamp;
        vm.prank(user);
        uint256 newExpiry = manager.topupAnnual(topicId, address(usdc), minUsdc, user, 499e18, block.timestamp);

        assertEq(newExpiry, t0 + manager.ONE_YEAR(), "annual topup should add one year");
        assertEq(manager.hasAccess(topicId, user), true, "annual member should have access");
    }

    function testAnnualPriceDefaultsToTwelveMonthlyPrices() external {
        bytes32 topicId = _hashTopic("annual.default");
        _createTopic(topicId, 50e18);

        assertEq(manager.getTopicAnnualPriceWad(topicId), 600e18, "default annual price should be 12 months");
        assertEq(manager.quoteMinTokenForAnnual(topicId, address(usdc)), 600e6, "default annual quote mismatch");
    }

    function testSetAndExtendExpirySupportOpsCompensation() external {
        bytes32 topicId = _hashTopic("ops.manual.expiry");
        _createTopic(topicId, 100e18);

        uint256 initialExpiry = block.timestamp + 2 days;
        vm.prank(owner);
        manager.setExpiry(topicId, user, initialExpiry);

        assertEq(manager.getExpiry(topicId, user), initialExpiry, "manual expiry mismatch");
        assertEq(manager.hasAccess(topicId, user), true, "manual expiry should grant access");

        vm.warp(block.timestamp + 3 days);

        vm.prank(owner);
        uint256 newExpiry = manager.extendExpiry(topicId, user, 1 days);

        assertEq(newExpiry, block.timestamp + 1 days, "extension should start from now once expired");
        assertEq(manager.getExpiry(topicId, user), newExpiry, "stored expiry should update");
        assertEq(manager.hasAccess(topicId, user), true, "extended expiry should restore access");
    }

    function testWhitelistNoFeeAndBlockTopup() external {
        bytes32 topicId = _hashTopic("paid.whitelist");
        _createTopic(topicId, 100e18);

        vm.prank(owner);
        manager.setWhitelist(topicId, user, true);

        assertEq(manager.hasAccess(topicId, user), true, "whitelist should grant access");

        _approveAndMint(address(usdc), user, 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.WhitelistedUserNoPaymentRequired.selector, topicId, user
            )
        );
        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);
    }

    function testUSDC6DecimalsTopupAndExpiry() external {
        bytes32 topicId = _hashTopic("paid.usdc");
        _createTopic(topicId, 100e18);

        _approveAndMint(address(usdc), user, 100e6);

        uint256 t0 = block.timestamp;
        vm.prank(user);
        uint256 newExpiry = manager.topup(topicId, address(usdc), 100e6, user);

        assertEq(newExpiry, t0 + ONE_MONTH, "usdc expiry mismatch");
        assertEq(manager.getExpiry(topicId, user), t0 + ONE_MONTH, "stored expiry mismatch");
        assertEq(manager.hasAccess(topicId, user), true, "user should have access");
    }

    function testBNBTopupViaOracleQuote() external {
        bytes32 topicId = _hashTopic("paid.bnb");
        _createTopic(topicId, 100e18);

        uint256 minBnb = manager.quoteMinBnbForOneMonth(topicId);

        uint256 t0 = block.timestamp;
        vm.prank(user);
        uint256 newExpiry = manager.topup{ value: minBnb }(topicId, address(0), minBnb, user);

        assertGte(newExpiry, t0 + ONE_MONTH, "bnb expiry should be >= 1 month");
    }

    function testRambleTopupViaPairAndDiscount() external {
        bytes32 topicId = _hashTopic("paid.ramble");
        _createTopic(topicId, 50e18);

        uint256 minRamble = manager.quoteMinRambleForOneMonth(topicId);
        assertTrue(minRamble > 0, "ramble quote should be > 0");

        _approveAndMint(address(ramble), user, minRamble);
        uint256 nativeBefore = address(manager).balance;
        uint256 managerRambleBefore = ramble.balanceOf(address(manager));

        uint256 t0 = block.timestamp;
        (, uint256 effectiveValue,) = manager.previewTopup(topicId, address(ramble), minRamble);
        vm.prank(user);
        uint256 newExpiry = manager.topup(topicId, address(ramble), minRamble, user, effectiveValue, block.timestamp);

        assertGte(newExpiry, t0 + ONE_MONTH, "ramble expiry should be >= 1 month");
        assertTrue(address(manager).balance > nativeBefore, "ramble topup should swap into native BNB");
        assertEq(ramble.balanceOf(address(manager)), managerRambleBefore, "manager should not retain ramble");
    }

    function testRambleTopupUsesActualNativeReceivedAfterWithdraw() external {
        bytes32 topicId = _hashTopic("paid.ramble.native.received");
        _createTopic(topicId, 50e18);

        MockWBNBUnderpay shortPayTemplate = new MockWBNBUnderpay();
        vm.etch(address(wbnb), address(shortPayTemplate).code);

        MockPancakePairV2 shortPayPair = new MockPancakePairV2(address(ramble), address(wbnb));
        uint112 reserveRamble = uint112(1_000_000e18);
        uint112 reserveWbnb = uint112(10_000e18);
        shortPayPair.setReserves(reserveRamble, reserveWbnb, uint32(block.timestamp));
        ramble.mint(address(shortPayPair), reserveRamble);
        MockWBNB(payable(address(wbnb))).mint(address(shortPayPair), reserveWbnb);
        vm.deal(address(wbnb), 100_000 ether);

        vm.prank(owner);
        manager.setRamblePair(address(shortPayPair));

        uint256 minRamble = manager.quoteMinRambleForOneMonth(topicId);
        (, uint256 previewEffectiveValue,) = manager.previewTopup(topicId, address(ramble), minRamble);
        _approveAndMint(address(ramble), user, minRamble);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.EffectiveValueBelowMinimum.selector,
                previewEffectiveValue / 2,
                previewEffectiveValue
            )
        );
        vm.prank(user);
        manager.topup(topicId, address(ramble), minRamble, user, previewEffectiveValue, block.timestamp);
    }

    function testConfigurable24DecimalsNormalization() external {
        bytes32 topicId = _hashTopic("paid.usdc24");
        _createTopic(topicId, 100e18);

        vm.prank(owner);
        manager.setStableToken(address(usdc24), true);

        (, uint8 usdcDecimals) = manager.getStableTokenConfig(address(usdc24));
        assertEq(uint256(usdcDecimals), 24, "token decimals should be auto-read");

        uint256 amount24 = 100e24;
        _approveAndMint(address(usdc24), user, amount24);

        uint256 t0 = block.timestamp;
        vm.prank(user);
        uint256 newExpiry = manager.topup(topicId, address(usdc24), amount24, user);

        assertEq(newExpiry, t0 + ONE_MONTH, "24-decimal normalization mismatch");
    }

    function testOracleConfiguredTokenPreviewAndTopup() external {
        bytes32 topicId = _hashTopic("paid.weth.oracle");
        _createTopic(topicId, 100e18);

        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockAggregatorV3 wethOracle = new MockAggregatorV3(8);
        wethOracle.setLatestRoundData(1, int256(2500e8), block.timestamp, block.timestamp, 1);

        vm.prank(owner);
        manager.setPaymentToken(address(weth), true, address(wethOracle));

        (, uint8 tokenDecimals, address usdOracle, uint8 oracleDecimals) = manager.getPaymentTokenConfig(address(weth));
        assertEq(uint256(tokenDecimals), 18, "weth decimals mismatch");
        assertEq(usdOracle, address(wethOracle), "weth oracle mismatch");
        assertEq(uint256(oracleDecimals), 8, "oracle decimals mismatch");

        uint256 amountIn = 0.04 ether;
        (uint256 rawValueWad, uint256 effectiveValueWad, uint256 secondsAdded) =
            manager.previewTopup(topicId, address(weth), amountIn);

        assertEq(rawValueWad, 100e18, "oracle token raw value mismatch");
        assertEq(effectiveValueWad, 100e18, "oracle token effective value mismatch");
        assertEq(secondsAdded, ONE_MONTH, "oracle token seconds mismatch");
        assertEq(manager.quoteMinTokenForOneMonth(topicId, address(weth)), amountIn, "oracle min quote mismatch");

        _approveAndMint(address(weth), user, amountIn);
        vm.prank(user);
        uint256 newExpiry = manager.topup(topicId, address(weth), amountIn, user, 100e18, block.timestamp);

        assertEq(newExpiry, block.timestamp + ONE_MONTH, "oracle token topup expiry mismatch");
    }

    function testStableTopupUsesActualReceivedAmount() external {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("Fee USD", "FUSD", 6, 1000);
        bytes32 topicId = _hashTopic("paid.fee.stable");
        _createTopic(topicId, 100e18);

        vm.prank(owner);
        manager.setStableToken(address(feeToken), true);

        feeToken.mint(user, 100e6);
        vm.prank(user);
        feeToken.approve(address(manager), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.MinimumPaymentNotMet.selector, 90e18, 100e18)
        );
        vm.prank(user);
        manager.topup(topicId, address(feeToken), 100e6, user);
    }

    function testGuardedTopupRejectsEffectiveValueBelowUserMinimum() external {
        bytes32 topicId = _hashTopic("paid.bnb.guarded");
        _createTopic(topicId, 100e18);

        (, uint256 effectiveValueWad,) = manager.previewTopup(topicId, address(0), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.EffectiveValueBelowMinimum.selector,
                effectiveValueWad,
                effectiveValueWad + 1
            )
        );
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user, effectiveValueWad + 1, block.timestamp);
    }

    function testSetStableTokenRejectsUnsupportedDecimals() external {
        MockERC20 weird = new MockERC20("WEIRD", "WEIRD", 37);

        vm.expectRevert(abi.encodeWithSelector(WadScaleLib.InvalidDecimals.selector, uint8(37)));
        vm.prank(owner);
        manager.setStableToken(address(weird), true);
    }

    function testSetStableTokenRejectsRambleToken() external {
        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.InvalidStableToken.selector, address(ramble))
        );
        vm.prank(owner);
        manager.setStableToken(address(ramble), true);
    }

    function testSetRamblePairRejectsPairWithoutRamble() external {
        MockPancakePairV2 wrongPair = new MockPancakePairV2(address(usdc), address(wbnb));

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.PairTokenMismatch.selector, address(usdc), address(wbnb), address(ramble)
            )
        );
        vm.prank(owner);
        manager.setRamblePair(address(wrongPair));
    }

    function testSetRamblePairRejectsPairWithoutPinnedWbnb() external {
        MockPancakePairV2 invalidPair = new MockPancakePairV2(address(ramble), address(usdc));

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.InvalidWrappedNative.selector, address(usdc), address(wbnb)
            )
        );
        vm.prank(owner);
        manager.setRamblePair(address(invalidPair));
    }

    function testSetRamblePairRejectsPinnedWbnbWithoutWithdraw() external {
        MockPancakePairV2 invalidPair = new MockPancakePairV2(address(ramble), address(wbnb));

        vm.etch(address(wbnb), address(usdc).code);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.WrappedNativeWithdrawFailed.selector, address(wbnb))
        );
        vm.prank(owner);
        manager.setRamblePair(address(invalidPair));
    }

    function testInitializeOffBscLeavesRamblePairUnset() external {
        vm.chainId(1);

        TopicAccessManagerUpgradeable offBscImplementation = new TopicAccessManagerUpgradeable();
        bytes memory initData =
            abi.encodeCall(TopicAccessManagerUpgradeable.initialize, (owner, address(oracle), uint256(3600)));

        TestERC1967Proxy proxy = new TestERC1967Proxy(address(offBscImplementation), initData);
        TopicAccessManagerUpgradeable offBscManager = TopicAccessManagerUpgradeable(payable(address(proxy)));

        assertEq(offBscManager.getRamblePair(), address(0), "ramble pair should stay unset off bsc");
    }
}
