// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/TopicAccessFixture.sol";

contract TopicAccessManagerFuzzTest is TopicAccessFixture {
    bytes32 private _topicId;

    function setUp() public override {
        super.setUp();
        _topicId = _hashTopic("fuzz.preview");
        _createTopic(_topicId, 1e18);
    }

    function testFuzzToWadMatchesExpected(
        uint256 amount,
        uint8 decimals
    ) external view {
        decimals = uint8(bound(decimals, 0, 24));
        amount = bound(amount, 0, 1e30);

        uint256 expected = _toWadExpected(amount, decimals);
        uint256 got = wadHarness.toWad(amount, decimals);

        assertEq(got, expected, "toWad mismatch");
    }

    function testFuzzRoundTripForDecimalsLe18(
        uint256 amount,
        uint8 decimals
    ) external view {
        decimals = uint8(bound(decimals, 0, 18));
        amount = bound(amount, 0, 1e30);

        uint256 wad = wadHarness.toWad(amount, decimals);
        uint256 roundTrip = wadHarness.fromWadRoundUp(wad, decimals);

        assertEq(roundTrip, amount, "round trip <=18 should be exact");
    }

    function testFuzzRoundTripForDecimalsGt18(
        uint256 amount,
        uint8 decimals
    ) external view {
        decimals = uint8(bound(decimals, 19, 30));
        amount = bound(amount, 0, 1e36);

        uint256 k = pow10(decimals - 18);
        uint256 expected = (amount / k) * k;

        uint256 wad = wadHarness.toWad(amount, decimals);
        uint256 roundTrip = wadHarness.fromWadRoundUp(wad, decimals);

        assertEq(roundTrip, expected, "round trip >18 should be floor bucket");
        assertTrue(roundTrip <= amount, "round trip >18 should not exceed original");
    }

    function testFuzzPreviewTopupSecondsFormula(
        uint256 priceWad,
        uint256 amountWad
    ) external {
        priceWad = bound(priceWad, 1e15, 1e24);

        uint256 maxAmount = priceWad * 1000;
        amountWad = bound(amountWad, priceWad, maxAmount);

        vm.prank(owner);
        manager.setTopicPrice(_topicId, priceWad);

        (uint256 rawValueWad, uint256 effectiveValueWad, uint256 secondsAdded) =
            manager.previewTopup(_topicId, address(usdt), amountWad);

        uint256 expectedSeconds = (amountWad * ONE_MONTH) / priceWad;

        assertEq(rawValueWad, amountWad, "raw value mismatch");
        assertEq(effectiveValueWad, amountWad, "effective value mismatch");
        assertEq(secondsAdded, expectedSeconds, "seconds formula mismatch");
    }

    function _toWadExpected(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) {
            return amount;
        }
        if (decimals < 18) {
            return amount * pow10(18 - decimals);
        }

        return amount / pow10(decimals - 18);
    }
}
