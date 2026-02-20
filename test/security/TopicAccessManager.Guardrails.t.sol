// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/TopicAccessFixture.sol";

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
        manager.topup(topicId, address(ramble), 1e18, user);

        assertEq(address(manager).balance, managerNativeBefore, "manager native balance must rollback");
        assertEq(ramble.balanceOf(address(manager)), managerRambleBefore, "manager ramble balance must rollback");
        assertEq(ramble.balanceOf(address(pair)), pairRambleBefore, "pair ramble balance must rollback");
        assertEq(wbnb.balanceOf(address(pair)), pairWbnbBefore, "pair wbnb balance must rollback");
    }

    function testSetOracleConfigRejectsInvalidInput() external {
        vm.expectRevert(TopicAccessManagerUpgradeable.InvalidOracleConfig.selector);
        vm.prank(owner);
        manager.setOracleConfig(address(0), 3600);

        vm.expectRevert(TopicAccessManagerUpgradeable.InvalidOracleConfig.selector);
        vm.prank(owner);
        manager.setOracleConfig(address(oracle), 0);
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

    function testOracleInvalidPriceRejectsBnbPath() external {
        bytes32 topicId = _hashTopic("guard.oracle.invalid");
        _createTopic(topicId, 1e18);

        oracle.setLatestRoundData(2, int256(0), block.timestamp, block.timestamp, 2);

        vm.expectRevert(TopicAccessManagerUpgradeable.OraclePriceInvalid.selector);
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user);
    }
}
