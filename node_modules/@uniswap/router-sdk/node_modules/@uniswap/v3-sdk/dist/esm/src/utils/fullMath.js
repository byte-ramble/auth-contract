import JSBI from 'jsbi';
import { ONE, ZERO } from '../internalConstants';
export class FullMath {
    /**
     * Cannot be constructed.
     */
    constructor() { }
    static mulDivRoundingUp(a, b, denominator) {
        const product = JSBI.multiply(a, b);
        let result = JSBI.divide(product, denominator);
        if (JSBI.notEqual(JSBI.remainder(product, denominator), ZERO))
            result = JSBI.add(result, ONE);
        return result;
    }
}
//# sourceMappingURL=fullMath.js.map