declare const a: any;
const n: number = a;
let u: unknown;
u = 1;
u = "x";
declare const nv: never;
const ok: number = nv;
const bad: number = u;
