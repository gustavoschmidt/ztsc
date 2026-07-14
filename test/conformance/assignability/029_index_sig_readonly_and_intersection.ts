// readonly index signatures relate like mutable ones; an intersection of two
// interfaces (neither carrying an index) fails a string-index target.
type ROIdx = { readonly [k: string]: number };
const r1: ROIdx = { a: 1, b: 2 };
type TL = { a: number };
declare const tl: TL;
const r2: ROIdx = tl;
interface IFace2 { a: number; }
declare const i: IFace2;
const r3: ROIdx = i;
interface IA { a: number; }
interface IB { b: number; }
declare const iab: IA & IB;
type SIdx = { [k: string]: number };
const r4: SIdx = iab;
type A = { a: number };
type B = { b: number };
declare const ab: A & B;
const r5: SIdx = ab;
