import JSBI from 'jsbi';
import { subIn256 } from '.';
const Q128 = JSBI.exponentiate(JSBI.BigInt(2), JSBI.BigInt(128));
export class PositionLibrary {
    /**
     * Cannot be constructed.
     */
    constructor() { }
    // replicates the portions of Position#update required to compute unaccounted fees
    static getTokensOwed(feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity, feeGrowthInside0X128, feeGrowthInside1X128) {
        const tokensOwed0 = JSBI.divide(JSBI.multiply(subIn256(feeGrowthInside0X128, feeGrowthInside0LastX128), liquidity), Q128);
        const tokensOwed1 = JSBI.divide(JSBI.multiply(subIn256(feeGrowthInside1X128, feeGrowthInside1LastX128), liquidity), Q128);
        return [tokensOwed0, tokensOwed1];
    }
}
//# sourceMappingURL=position.js.map