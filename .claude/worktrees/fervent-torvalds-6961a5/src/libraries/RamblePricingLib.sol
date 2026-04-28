// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";

library RamblePricingLib {
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
