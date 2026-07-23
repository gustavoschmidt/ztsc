type M = typeof import("./lib");
declare const m: M;
const ctx = m.make<number>(3);
const okVal: number = ctx.value;
const okVer: string = m.VERSION;
const wrong: number = m.VERSION;
m.missing();
