import JSBI from 'jsbi';
import invariant from 'tiny-invariant';
import { TickMath } from '../utils';
export class Tick {
    constructor({ index, liquidityGross, liquidityNet }) {
        invariant(index >= TickMath.MIN_TICK && index <= TickMath.MAX_TICK, 'TICK');
        this.index = index;
        this.liquidityGross = JSBI.BigInt(liquidityGross);
        this.liquidityNet = JSBI.BigInt(liquidityNet);
    }
}
//# sourceMappingURL=tick.js.map