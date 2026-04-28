// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../libraries/WadScaleLib.sol";

contract WadScaleHarness {
    function toWad(
        uint256 amount,
        uint8 decimals
    ) external pure returns (uint256) {
        return WadScaleLib.toWad(amount, decimals);
    }

    function fromWadRoundUp(
        uint256 wadAmount,
        uint8 decimals
    ) external pure returns (uint256) {
        return WadScaleLib.fromWadRoundUp(wadAmount, decimals);
    }
}
