function id<T>(x: T): T { return x; }
const n: number = id(1);
const s: string = id("a");
const lit: "a" = id("a");
const e: number = id<number>(2);
