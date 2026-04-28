import JSBI from 'jsbi';
import { NEGATIVE_ONE, ZERO } from '../internalConstants';
export class LiquidityMath {
    /**
     * Cannot be constructed.
     */
    constructor() { }
    static addDelta(x, y) {
        if (JSBI.lessThan(y, ZERO)) {
            return JSBI.subtract(x, JSBI.multiply(y, NEGATIVE_ONE));
        }
        else {
            return JSBI.add(x, y);
        }
    }
}
//# sourceMappingURL=liquidityMath.js.map