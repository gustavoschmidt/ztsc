type AB = { a: number } & { b: string };
declare const both: { a: number; b: string };
const x: AB = both;
declare const ab: AB;
const a: { a: number } = ab;
const b: { b: string } = ab;
declare const onlyA: { a: number };
const bad: AB = onlyA;
