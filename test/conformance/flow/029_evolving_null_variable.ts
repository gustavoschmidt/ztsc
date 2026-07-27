// A `let`/`var` with no type annotation and a `null` / `undefined`
// initializer gets tsc's "auto" type: the declared type is a starting point,
// not a constraint. Writes are unchecked and a read takes the type the flow
// last assigned.
declare function pick(): { index: number } | null;

let n = null;
n = 5;
const k: number = n;

let u = undefined;
u = "hi";
const s: string = u;

var v = null;
v = true;
const b: boolean = v;

// Union at a join.
declare const cond: boolean;
let w = null;
if (cond) {
  w = 1;
} else {
  w = "x";
}
const q: number | string = w;

// Compound assignment.
let c1 = null;
c1 = 1;
c1 += 2;
const c2: number = c1;

// Reassigned through a loop.
let acc = null;
for (let i = 0; i < 3; i++) {
  acc = i;
}

// Object shape.
let o = null;
o = pick();
const oo: { index: number } | null = o;

// A read before any assignment still sees the initializer type.
let r = null;
const rr: null = r;
let r2 = undefined;
const rr2: undefined = r2;

// Assignment from a nested function is allowed.
let g = null;
function h() {
  g = 7;
}
h();
