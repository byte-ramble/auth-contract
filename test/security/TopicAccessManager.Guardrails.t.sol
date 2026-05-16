// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/TopicAccessFixture.sol";
import "../../src/mocks/MockFeeOnTransferERC20.sol";

contract TopicAccessManagerGuardrailsTest is TopicAccessFixture {
    function testHashTopicKeyRejectsEmptyInput() external {
        vm.expectRevert(TopicAccessManagerUpgradeable.EmptyTopicKey.selector);
        manager.hashTopicKey("");
    }

    function testCreateTopicRejectsZeroTopicId() external {
        vm.expectRevert(TopicAccessManagerUpgradeable.InvalidTopicId.selector);
        vm.prank(owner);
        manager.createTopic(bytes32(0), 1e18);
    }

    function testCreateTopicRejectsDuplicateTopicId() external {
        bytes32 topicId = _hashTopic("guard.duplicate");
        _createTopic(topicId, 1e18);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.TopicAlreadyExists.selector, topicId));
        vm.prank(owner);
        manager.createTopic(topicId, 2e18);
    }

    function testBatchSetWhitelistRejectsZeroAddress() external {
        bytes32 topicId = _hashTopic("guard.batch.whitelist");
        _createTopic(topicId, 1e18);

        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = address(0);

        vm.expectRevert(TopicAccessManagerUpgradeable.ZeroAddress.selector);
        vm.prank(owner);
        manager.batchSetWhitelist(topicId, users, true);
    }

    function testBatchSetWhitelistUpdatesUsers() external {
        bytes32 topicId = _hashTopic("guard.batch.whitelist.ok");
        _createTopic(topicId, 1e18);

        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = user2;

        vm.prank(owner);
        manager.batchSetWhitelist(topicId, users, true);

        assertEq(manager.isWhitelisted(topicId, user), true, "user should be whitelisted");
        assertEq(manager.isWhitelisted(topicId, user2), true, "user2 should be whitelisted");
    }

    function testHasAccessReturnsFalseWhenTopicMissing() external view {
        bytes32 missingTopic = _hashTopic("guard.missing.topic");
        assertEq(manager.hasAccess(missingTopic, user), false, "missing topic must not grant access");
    }

    function testTopupRejectsZeroAmount() external {
        bytes32 topicId = _hashTopic("guard.zero.amount");
        _createTopic(topicId, 1e18);

        vm.expectRevert(TopicAccessManagerUpgradeable.AmountZero.selector);
        vm.prank(user);
        manager.topup(topicId, address(usdc), 0, user);
    }

    function testTopupRejectsZeroBeneficiary() external {
        bytes32 topicId = _hashTopic("guard.zero.beneficiary");
        _createTopic(topicId, 1e18);
        _approveAndMint(address(usdc), user, 1e6);

        vm.expectRevert(TopicAccessManagerUpgradeable.ZeroAddress.selector);
        vm.prank(user);
        manager.topup(topicId, address(usdc), 1e6, address(0));
    }

    function testGuardedTopupRejectsExpiredDeadline() external {
        bytes32 topicId = _hashTopic("guard.expired.deadline");
        _createTopic(topicId, 1e18);

        vm.warp(10_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.PaymentDeadlineExpired.selector, uint256(9999), uint256(10_000)
            )
        );
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user, 0, 9999);
    }

    function testTopupRejectsUnsupportedToken() external {
        bytes32 topicId = _hashTopic("guard.unsupported.token");
        _createTopic(topicId, 1e18);

        MockERC20 unknown = new MockERC20("UNKNOWN", "UNKNOWN", 18);
        _approveAndMint(address(unknown), user, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.UnsupportedPayToken.selector, address(unknown))
        );
        vm.prank(user);
        manager.topup(topicId, address(unknown), 1e18, user);
    }

    function testTopupRejectsNativeValueMismatch() external {
        bytes32 topicId = _hashTopic("guard.native.mismatch");
        _createTopic(topicId, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.NativeValueMismatch.selector, 2 ether, 1 ether)
        );
        vm.prank(user);
        manager.topup{ value: 2 ether }(topicId, address(0), 1 ether, user);
    }

    function testTopupRejectsUnexpectedNativeValue() external {
        bytes32 topicId = _hashTopic("guard.unexpected.native");
        _createTopic(topicId, 1e18);
        _approveAndMint(address(usdc), user, 1e6);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.UnexpectedNativeValue.selector, 1 wei));
        vm.prank(user);
        manager.topup{ value: 1 wei }(topicId, address(usdc), 1e6, user);
    }

    function testTopupRejectsBelowMinimumPayment() external {
        bytes32 topicId = _hashTopic("guard.min.payment");
        _createTopic(topicId, 2e18);
        _approveAndMint(address(usdc), user, 1e6);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.MinimumPaymentNotMet.selector, 1e18, 2e18));
        vm.prank(user);
        manager.topup(topicId, address(usdc), 1e6, user);
    }

    function testDisabledStableTokenCannotBeUsedForTopup() external {
        bytes32 topicId = _hashTopic("guard.disabled.stable");
        _createTopic(topicId, 1e18);
        _approveAndMint(address(usdc), user, 1e6);

        vm.prank(owner);
        manager.setStableToken(address(usdc), false);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.UnsupportedPayToken.selector, address(usdc))
        );
        vm.prank(user);
        manager.topup(topicId, address(usdc), 1e6, user);
    }

    function testSetPaymentTokenRejectsMissingOracle() external {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.PaymentTokenOracleRequired.selector, address(weth))
        );
        vm.prank(owner);
        manager.setPaymentToken(address(weth), true, address(0));
    }

    function testQuoteMinTokenRejectsUnsupportedToken() external {
        bytes32 topicId = _hashTopic("guard.quote.unsupported.token");
        _createTopic(topicId, 100e18);

        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.UnsupportedPayToken.selector, address(weth))
        );
        manager.quoteMinTokenForOneMonth(topicId, address(weth));
    }

    function testGuardedStableTopupRejectsFeeOnTransferBelowUserMinimum() external {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("Fee USD", "FUSD", 6, 500);
        bytes32 topicId = _hashTopic("guard.fee.stable.user.min");
        _createTopic(topicId, 90e18);

        vm.prank(owner);
        manager.setStableToken(address(feeToken), true);

        feeToken.mint(user, 100e6);
        vm.prank(user);
        feeToken.approve(address(manager), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.EffectiveValueBelowMinimum.selector, 95e18, 100e18)
        );
        vm.prank(user);
        manager.topup(topicId, address(feeToken), 100e6, user, 100e18, block.timestamp);
    }

    function testTopicPaymentAllowlistRejectsDisallowedTokenAcrossQuotePreviewAndTopup() external {
        bytes32 topicId = _hashTopic("guard.topic.token.allowlist");
        _createTopic(topicId, 100e18);
        _approveAndMint(address(usdc), user, 100e6);

        vm.prank(owner);
        manager.setTopicPaymentAllowlistEnabled(topicId, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.PayTokenNotAllowedForTopic.selector, topicId, address(usdc)
            )
        );
        manager.quoteMinTokenForOneMonth(topicId, address(usdc));

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.PayTokenNotAllowedForTopic.selector, topicId, address(usdc)
            )
        );
        manager.previewTopup(topicId, address(usdc), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.PayTokenNotAllowedForTopic.selector, topicId, address(usdc)
            )
        );
        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);
    }

    function testRambleTopupBelowMinimumRevertsAtomically() external {
        bytes32 topicId = _hashTopic("guard.ramble.min.payment");
        _createTopic(topicId, 10_000_000e18);
        _approveAndMint(address(ramble), user, 1e18);
        (, uint256 effectiveValueWad,) = manager.previewTopup(topicId, address(ramble), 1e18);
        uint256 monthlyPriceWad = manager.getTopicPriceWad(topicId);

        uint256 managerNativeBefore = address(manager).balance;
        uint256 managerRambleBefore = ramble.balanceOf(address(manager));
        uint256 pairRambleBefore = ramble.balanceOf(address(pair));
        uint256 pairWbnbBefore = wbnb.balanceOf(address(pair));

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.MinimumPaymentNotMet.selector, effectiveValueWad, monthlyPriceWad
            )
        );
        vm.prank(user);
        manager.topup(topicId, address(ramble), 1e18, user, 1e18, block.timestamp);

        assertEq(address(manager).balance, managerNativeBefore, "manager native balance must rollback");
        assertEq(ramble.balanceOf(address(manager)), managerRambleBefore, "manager ramble balance must rollback");
        assertEq(ramble.balanceOf(address(pair)), pairRambleBefore, "pair ramble balance must rollback");
        assertEq(wbnb.balanceOf(address(pair)), pairWbnbBefore, "pair wbnb balance must rollback");
    }

    function testRambleTopupRejectsUnguardedPath() external {
        bytes32 topicId = _hashTopic("guard.ramble.unguarded");
        _createTopic(topicId, 1e18);
        _approveAndMint(address(ramble), user, 1e18);

        vm.expectRevert(TopicAccessManagerUpgradeable.RambleSlippageProtectionRequired.selector);
        vm.prank(user);
        manager.topup(topicId, address(ramble), 1e18, user);
    }

    function testSetOracleConfigRejectsInvalidInput() external {
        vm.expectRevert(TopicAccessManagerUpgradeable.InvalidOracleConfig.selector);
        vm.prank(owner);
        manager.setOracleConfig(address(0), 3600);

        vm.expectRevert(TopicAccessManagerUpgradeable.InvalidOracleConfig.selector);
        vm.prank(owner);
        manager.setOracleConfig(address(oracle), 0);
    }

    function testSetOracleConfigRejectsNoCodeOracle() external {
        address noCodeOracle = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.InvalidOracle.selector, noCodeOracle));
        vm.prank(owner);
        manager.setOracleConfig(noCodeOracle, 3600);
    }

    function testSetOracleConfigRejectsWrongInterfaceAddress() external {
        MockERC20 notOracle = new MockERC20("Not Oracle", "NOR", 18);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.InvalidOracle.selector, address(notOracle))
        );
        vm.prank(owner);
        manager.setOracleConfig(address(notOracle), 3600);
    }

    function testSetOracleConfigRejectsStaleOracleAtConfigurationTime() external {
        uint256 nowTs = 20_000;
        vm.warp(nowTs);

        uint256 staleAt = nowTs - 3700;
        oracle.setLatestRoundData(2, int256(30_000_000_000), staleAt, staleAt, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.OraclePriceStale.selector, staleAt, nowTs, uint256(3600)
            )
        );
        vm.prank(owner);
        manager.setOracleConfig(address(oracle), 3600);
    }

    function testSetExpiryRejectsZeroAddress() external {
        bytes32 topicId = _hashTopic("guard.expiry.zero.user");
        _createTopic(topicId, 1e18);

        vm.expectRevert(TopicAccessManagerUpgradeable.ZeroAddress.selector);
        vm.prank(owner);
        manager.setExpiry(topicId, address(0), block.timestamp + 1 days);
    }

    function testExtendExpiryRejectsZeroDuration() external {
        bytes32 topicId = _hashTopic("guard.expiry.zero.duration");
        _createTopic(topicId, 1e18);

        vm.expectRevert(TopicAccessManagerUpgradeable.DurationZero.selector);
        vm.prank(owner);
        manager.extendExpiry(topicId, user, 0);
    }

    function testSetStableTokenRejectsZeroAddress() external {
        vm.expectRevert(TopicAccessManagerUpgradeable.ZeroAddress.selector);
        vm.prank(owner);
        manager.setStableToken(address(0), true);
    }

    function testSetStableTokenRejectsNoCodeAddress() external {
        address noCodeToken = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.InvalidStableToken.selector, noCodeToken));
        vm.prank(owner);
        manager.setStableToken(noCodeToken, true);
    }

    function testSetRamblePairRejectsZeroAddress() external {
        vm.expectRevert(TopicAccessManagerUpgradeable.ZeroAddress.selector);
        vm.prank(owner);
        manager.setRamblePair(address(0));
    }

    function testSetRamblePairRejectsNoCodeAddress() external {
        address noCodePair = address(0xCAFE);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.RamblePairNotConfigured.selector, noCodePair)
        );
        vm.prank(owner);
        manager.setRamblePair(noCodePair);
    }

    function testRambleQuoteRejectsLowLiquidityPair() external {
        bytes32 topicId = _hashTopic("guard.low.liq");
        _createTopic(topicId, 1e18);

        pair.setReserves(0, 0, uint32(block.timestamp));

        vm.expectRevert(TopicAccessManagerUpgradeable.PairLiquidityTooLow.selector);
        manager.quoteMinRambleForOneMonth(topicId);
    }

    function testRamblePaymentRejectsOffBsc() external {
        bytes32 topicId = _hashTopic("guard.ramble.off.bsc");
        _createTopic(topicId, 1e18);
        _approveAndMint(address(ramble), user, 1e18);

        vm.chainId(1);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.RambleOnlySupportedOnBsc.selector, uint256(1))
        );
        manager.quoteMinRambleForOneMonth(topicId);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.RambleOnlySupportedOnBsc.selector, uint256(1))
        );
        manager.previewTopup(topicId, address(ramble), 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.RambleOnlySupportedOnBsc.selector, uint256(1))
        );
        vm.prank(user);
        manager.topup(topicId, address(ramble), 1e18, user);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.RambleOnlySupportedOnBsc.selector, uint256(1))
        );
        vm.prank(owner);
        manager.setRamblePair(address(pair));
    }

    function testOracleInvalidPriceRejectsBnbPath() external {
        bytes32 topicId = _hashTopic("guard.oracle.invalid");
        _createTopic(topicId, 1e18);

        oracle.setLatestRoundData(2, int256(0), block.timestamp, block.timestamp, 2);

        vm.expectRevert(TopicAccessManagerUpgradeable.OraclePriceInvalid.selector);
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user);
    }

    function testBatchSetWhitelistRejectsOversizedArray() external {
        bytes32 topicId = _hashTopic("guard.batch.oversize");
        _createTopic(topicId, 1e18);

        address[] memory users = new address[](201);
        for (uint256 i = 0; i < 201; ++i) {
            users[i] = address(uint160(0x2000 + i));
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.BatchSizeExceeded.selector, uint256(201), manager.MAX_BATCH_SIZE()
            )
        );
        vm.prank(owner);
        manager.batchSetWhitelist(topicId, users, true);
    }

    function testDeactivateTopicRejectsAlreadyDeactivated() external {
        bytes32 topicId = _hashTopic("guard.deactivate.double");
        _createTopic(topicId, 1e18);

        vm.startPrank(owner);
        manager.deactivateTopic(topicId);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.TopicIsDeactivated.selector, topicId));
        manager.deactivateTopic(topicId);
        vm.stopPrank();
    }

    function testReactivateTopicRejectsAlreadyActive() external {
        bytes32 topicId = _hashTopic("guard.reactivate.active");
        _createTopic(topicId, 1e18);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.TopicAlreadyActive.selector, topicId));
        vm.prank(owner);
        manager.reactivateTopic(topicId);
    }

    function testDeactivatedTopicRejectsTopup() external {
        bytes32 topicId = _hashTopic("guard.deactivated.topup");
        _createTopic(topicId, 100e18);
        _approveAndMint(address(usdc), user, 100e6);

        vm.prank(owner);
        manager.deactivateTopic(topicId);

        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.TopicIsDeactivated.selector, topicId));
        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);
    }
}
