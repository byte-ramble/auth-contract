// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RamblePricingLib
/// @notice RAMBLE / PancakeSwap V2 pricing helpers (BSC-only).
/// @dev All functions are stateless; iteration bounds are injected by the caller via `maxQuoteSearchSteps`.
library RamblePricingLib {
    /// @notice Finds the smallest input amount such that `quoteValueFn(amount).effectiveValueWad >= targetValueWad`.
    /// @dev Two-phase search:
    ///      1. Exponentially double `high` until it clears the target (or overflow risk ⇒ returns `false`).
    ///      2. Binary-search `(low, high]` for the smallest passing amount.
    ///      Both phases are capped by `maxQuoteSearchSteps`; exhaustion returns `(false, 0)`.
    /// @param targetValueWad Effective-value-in-WAD that must be met or exceeded.
    /// @param maxQuoteSearchSteps Upper bound on each search phase (defensive against pathological curves).
    /// @param quoteValueFn Function pointer returning `(rawValueWad, effectiveValueWad)` for an input amount.
    /// @return found True if a passing amount was found within the step budget.
    /// @return minAmount The smallest input satisfying the target; `0` when `found == false`.
    function quoteMinAmountForTargetValue(
        uint256 targetValueWad,
        uint256 maxQuoteSearchSteps,
        function(uint256) view returns (uint256, uint256) quoteValueFn
    ) internal view returns (bool found, uint256 minAmount) {
        uint256 high = 1;
        uint256 effectiveValueWad;

        for (uint256 i = 0; i < maxQuoteSearchSteps; ++i) {
            (, effectiveValueWad) = quoteValueFn(high);
            if (effectiveValueWad >= targetValueWad) {
                found = true;
                break;
            }

            if (high > type(uint256).max / 2) {
                return (false, 0);
            }

            high *= 2;
        }

        if (!found) {
            (, effectiveValueWad) = quoteValueFn(high);
            if (effectiveValueWad < targetValueWad) {
                return (false, 0);
            }
        }

        uint256 low = 0;
        for (uint256 i = 0; i < maxQuoteSearchSteps; ++i) {
            if (low + 1 >= high) {
                break;
            }

            uint256 mid = low + ((high - low) / 2);
            (, effectiveValueWad) = quoteValueFn(mid);

            if (effectiveValueWad >= targetValueWad) {
                high = mid;
            } else {
                low = mid;
            }
        }

        return (true, high);
    }

    /// @notice PancakeSwap V2 `getAmountOut` formula: `amountOut = (amountIn * feeNum * reserveOut) / (reserveIn * feeDen + amountIn * feeNum)`.
    /// @dev Returns `0` for zero input or a zero denominator (degenerate reserves). `feeNumerator = 9975`,
    ///      `feeDenominator = 10_000` encode PancakeSwap V2's 0.25% taker fee. Uses `Math.mulDiv` to avoid overflow.
    function getV2AmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeNumerator,
        uint256 feeDenominator
    ) internal pure returns (uint256) {
        if (amountIn == 0) {
            return 0;
        }

        uint256 amountInWithFee = amountIn * feeNumerator;
        uint256 denominator = (reserveIn * feeDenominator) + amountInWithFee;
        if (denominator == 0) {
            return 0;
        }

        return Math.mulDiv(amountInWithFee, reserveOut, denominator);
    }
}
