// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/TopicAccessFixture.sol";
import "../../src/libraries/WadScaleLib.sol";

contract TopicAccessManagerUnitTest is TopicAccessFixture {
    function testRambleConstantsAreApplied() external view {
        assertEq(manager.RAMBLE_TOKEN(), address(ramble), "ramble constant mismatch");
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
    }

    function testFreeTopicBoundary() external {
        bytes32 topicId = _hashTopic("free.topic");
        _createTopic(topicId, 0);

        assertEq(manager.hasAccess(topicId, user), true, "free topic should grant access");
        assertEq(manager.quoteMinBnbForOneMonth(topicId), 0, "free topic bnb quote should be zero");
        assertEq(manager.quoteMinRambleForOneMonth(topicId), 0, "free topic ramble quote should be zero");

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.FreeTopicNoPaymentRequired.selector, topicId)
        );
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user);
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
        vm.prank(user);
        uint256 newExpiry = manager.topup(topicId, address(ramble), minRamble, user);

        assertGte(newExpiry, t0 + ONE_MONTH, "ramble expiry should be >= 1 month");
        assertTrue(address(manager).balance > nativeBefore, "ramble topup should swap into native BNB");
        assertEq(ramble.balanceOf(address(manager)), managerRambleBefore, "manager should not retain ramble");
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

    function testSetRamblePairRejectsPairWithoutWrappedNativeWithdraw() external {
        MockPancakePairV2 invalidPair = new MockPancakePairV2(address(ramble), address(usdc));

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.WrappedNativeWithdrawFailed.selector, address(usdc))
        );
        vm.prank(owner);
        manager.setRamblePair(address(invalidPair));
    }
}
