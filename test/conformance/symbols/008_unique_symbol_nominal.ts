declare const some: symbol;
const k1: unique symbol = Symbol();
const k2: unique symbol = some;
const j: unique symbol = Symbol();
const o = { [k1]: 1, [j]: "s" };
const bad1: string = o[k1];
const bad2: number = o[j];
const ws: symbol = k1;
const bad3: unique symbol = k1;
