// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../base/TopicAccessFixture.sol";
import "../../src/mocks/MockERC20FalseReturn.sol";
import "../../src/mocks/ReentrantExecutorTarget.sol";

contract TopicAccessManagerSecurityTest is TopicAccessFixture {
    function testOnlyOwnerRestrictedFunctions() external {
        bytes32 topicId = _hashTopic("security.owner.only");

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        manager.createTopic(topicId, 1e18);

        _createTopic(topicId, 1e18);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        manager.setTopicPrice(topicId, 2e18);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        manager.setWhitelist(topicId, user, true);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        manager.setRambleDiscountBps(9000);
    }

    function testPauseBlocksTopupAndUnpauseRecovers() external {
        bytes32 topicId = _hashTopic("security.pause");
        _createTopic(topicId, 100e18);

        _approveAndMint(address(usdc), user, 100e6);

        vm.prank(owner);
        manager.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);

        vm.prank(owner);
        manager.unpause();

        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);

        assertTrue(manager.getExpiry(topicId, user) > block.timestamp, "expiry should be set after unpause");
    }

    function testOracleStaleRejectsBNBPath() external {
        bytes32 topicId = _hashTopic("security.oracle.stale");
        _createTopic(topicId, 100e18);

        uint256 nowTs = 10_000;
        vm.warp(nowTs);
        uint256 staleAt = nowTs - 3700;
        oracle.setLatestRoundData(2, int256(30_000_000_000), staleAt, staleAt, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.OraclePriceStale.selector, staleAt, nowTs, uint256(3600)
            )
        );
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user);
    }

    function testOracleRoundInvalidRejectsBNBPath() external {
        bytes32 topicId = _hashTopic("security.oracle.round.invalid");
        _createTopic(topicId, 100e18);

        oracle.setLatestRoundData(3, int256(30_000_000_000), block.timestamp, block.timestamp, 2);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.OracleRoundInvalid.selector, uint80(3), uint80(2))
        );
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user);
    }

    function testPrivilegedCallRequiresExecutor() external {
        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.NotExecutor.selector, attacker));
        vm.prank(attacker);
        manager.executePrivilegedCall(recipient, 0, "");
    }

    function testPrivilegedCallRejectsZeroAndSelfTarget() external {
        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.InvalidPrivilegedTarget.selector, address(0))
        );
        vm.prank(owner);
        manager.executePrivilegedCall(address(0), 0, "");

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.InvalidPrivilegedTarget.selector, address(manager))
        );
        vm.prank(owner);
        manager.executePrivilegedCall(address(manager), 0, "");
    }

    function testOwnerHasPrivilegedCallByDefault() external {
        uint256 value = 0.2 ether;
        vm.deal(address(manager), value);
        uint256 beforeBalance = recipient.balance;

        vm.prank(owner);
        (bool success,) = manager.executePrivilegedCall(recipient, value, "");

        assertEq(success, true, "owner privileged call should succeed");
        assertEq(recipient.balance - beforeBalance, value, "recipient should receive native token");
    }

    function testOwnerCanWithdrawNativeViaTypedHelper() external {
        uint256 value = 0.2 ether;
        vm.deal(address(manager), value);
        uint256 beforeBalance = recipient.balance;

        vm.prank(owner);
        manager.withdrawNative(recipient, value);

        assertEq(recipient.balance - beforeBalance, value, "recipient should receive native token");
    }

    function testOwnerCanWithdrawErc20ViaTypedHelper() external {
        uint256 amount = 50e6;
        usdc.mint(address(manager), amount);
        uint256 beforeBalance = usdc.balanceOf(recipient);

        vm.prank(owner);
        manager.withdrawERC20(address(usdc), recipient, amount);

        assertEq(usdc.balanceOf(recipient) - beforeBalance, amount, "recipient should receive usdc");
    }

    function testExecutorCanCallAfterOwnerConfiguresExecutor() external {
        assertEq(manager.getExecutor(), address(0), "executor should default to zero");

        vm.prank(owner);
        manager.setExecutor(executor);

        uint256 value = 0.2 ether;
        vm.deal(address(manager), value);
        uint256 beforeBalance = recipient.balance;

        vm.prank(executor);
        (bool success,) = manager.executePrivilegedCall(recipient, value, "");

        assertEq(success, true, "configured executor call should succeed");
        assertEq(recipient.balance - beforeBalance, value, "recipient should receive native token");
    }

    function testPrivilegedCallRejectsDirectErc20TransferPayload() external {
        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.UseWithdrawERC20.selector, address(usdc)));
        vm.prank(owner);
        manager.executePrivilegedCall(address(usdc), 0, abi.encodeCall(IERC20.transfer, (recipient, 1e6)));
    }

    function testTypedErc20WithdrawRevertsOnFalseReturnToken() external {
        MockERC20FalseReturn brokenToken = new MockERC20FalseReturn();
        brokenToken.mint(address(manager), 1e18);

        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(brokenToken)));
        vm.prank(owner);
        manager.withdrawERC20(address(brokenToken), recipient, 1e18);

        assertEq(brokenToken.balanceOf(address(manager)), 1e18, "manager balance must remain");
        assertEq(brokenToken.balanceOf(recipient), 0, "recipient balance must remain zero");
    }

    function testReentrancyAttemptDuringPrivilegedCallFails() external {
        ReentrantExecutorTarget reentrant = new ReentrantExecutorTarget();

        vm.prank(owner);
        manager.setExecutor(executor);

        bytes memory attackData =
            abi.encodeCall(ReentrantExecutorTarget.reenter, (address(manager), recipient, bytes("")));

        vm.prank(executor);
        (bool success,) = manager.executePrivilegedCall(address(reentrant), 0, attackData);

        assertFalse(success, "reentrant privileged call should fail");
    }
}
