// A string-index target admits a source only via a compatible source index
// signature or an implied-index (object/type-literal) shape. Bare primitives,
// functions, arrays, class instances and interfaces without an index fail.
type SIdx = { [k: string]: number };
declare const p: number;
const a1: SIdx = p;
declare const f: () => number;
const a2: SIdx = f;
declare const arr: number[];
const a3: SIdx = arr;
declare const s: string;
const a4: SIdx = s;
class C { a = 1; b = 2; }
declare const c: C;
const a5: SIdx = c;
interface IFace { a: number; b: number; }
declare const i: IFace;
const a6: SIdx = i;
type Tup = [number, number];
declare const t: Tup;
const a7: SIdx = t;
