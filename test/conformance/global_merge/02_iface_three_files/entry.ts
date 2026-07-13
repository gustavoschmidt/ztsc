import "./x";
import "./y";
import "./z";
const full: Ctx = { a: 1, b: "s", c: true };
const partial: Ctx = { a: 1, b: "s" };
const n: number = full.a;
const s: string = full.b;
const wrong: number = full.c;
