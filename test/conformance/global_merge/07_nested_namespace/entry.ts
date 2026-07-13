import "./a";
import "./b";
const ok: Outer.Inner.Opts = { a: 1, b: "x" };
const partial: Outer.Inner.Opts = { a: 1 };
const n: number = ok.a;
const s: string = ok.b;
