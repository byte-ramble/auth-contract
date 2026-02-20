// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";

library WadScaleLib {
    uint8 internal constant WAD_DECIMALS = 18;
    uint8 internal constant MAX_DECIMALS = 36;

    error InvalidDecimals(uint8 decimals);

    function validateDecimals(
        uint8 decimals
    ) internal pure {
        if (decimals > MAX_DECIMALS) {
            revert InvalidDecimals(decimals);
        }
    }

    function pow10(
        uint8 exp
    ) internal pure returns (uint256 result) {
        result = 1;
        for (uint8 i = 0; i < exp; ++i) {
            result *= 10;
        }
    }

    function toWad(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        validateDecimals(decimals);

        if (decimals == WAD_DECIMALS) {
            return amount;
        }
        if (decimals < WAD_DECIMALS) {
            return amount * pow10(WAD_DECIMALS - decimals);
        }

        return amount / pow10(decimals - WAD_DECIMALS);
    }

    function fromWadRoundUp(
        uint256 wadAmount,
        uint8 decimals
    ) internal pure returns (uint256) {
        validateDecimals(decimals);

        if (decimals == WAD_DECIMALS) {
            return wadAmount;
        }
        if (decimals < WAD_DECIMALS) {
            uint256 divisor = pow10(WAD_DECIMALS - decimals);
            return Math.ceilDiv(wadAmount, divisor);
        }

        return wadAmount * pow10(decimals - WAD_DECIMALS);
    }
}
