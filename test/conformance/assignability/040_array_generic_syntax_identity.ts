// `Array<T>` / `ReadonlyArray<T>` are the same type as `T[]` / `readonly T[]`
// in both directions (tsc models them identically).
declare const a: Array<string>;
const b: string[] = a;
declare const c: string[];
const d: Array<string> = c;
const ro: ReadonlyArray<string> = c;
declare const ro2: ReadonlyArray<{ x: number }>;
const e: readonly { x: number }[] = ro2;
const bad: number[] = a; // TS2322
