// A source string index signature must have a value type assignable to the
// target's; a class instance carrying an inherited index passes.
type SIdxNum = { [k: string]: number };
declare const strIdxStr: { [k: string]: string };
const v1: SIdxNum = strIdxStr;
declare const strIdxNum: { [k: string]: number };
const v2: SIdxNum = strIdxNum;
interface Base { [k: string]: number; }
interface Derived extends Base { a: number; }
declare const d: Derived;
const v3: SIdxNum = d;
