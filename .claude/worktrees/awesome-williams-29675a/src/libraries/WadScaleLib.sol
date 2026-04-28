// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title WadScaleLib
/// @notice Helpers for converting token amounts between native decimals and the WAD (1e18) billing precision.
/// @dev All functions are pure. `MAX_DECIMALS = 36` caps the scaling factor so `pow10(...)` can never overflow.
library WadScaleLib {
    /// @notice Target precision for internal accounting (1e18).
    uint8 internal constant WAD_DECIMALS = 18;
    /// @notice Upper bound on accepted token / oracle decimals.
    uint8 internal constant MAX_DECIMALS = 36;

    /// @notice Thrown when a token or oracle reports decimals beyond `MAX_DECIMALS`.
    error InvalidDecimals(uint8 decimals);

    /// @notice Reverts with `InvalidDecimals` when `decimals > MAX_DECIMALS`.
    function validateDecimals(
        uint8 decimals
    ) internal pure {
        if (decimals > MAX_DECIMALS) {
            revert InvalidDecimals(decimals);
        }
    }

    /// @notice Returns `10 ** exp` without risking overflow for `exp <= MAX_DECIMALS`.
    function pow10(
        uint8 exp
    ) internal pure returns (uint256 result) {
        result = 1;
        for (uint8 i = 0; i < exp; ++i) {
            result *= 10;
        }
    }

    /// @notice Rescales `amount` from `decimals` to WAD (truncating when downscaling).
    /// @dev Records (bookkeeping) use truncation so we never credit more than the caller paid.
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

    /// @notice Rescales a WAD value back to `decimals`, rounding up.
    /// @dev Quotes round up so the returned amount always satisfies the required WAD value.
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
