// Expando properties on function values (TS 3.1 "properties declarations on
// functions"): a same-scope `fn.prop = value` statement declares `prop` on the
// function, with the widened type of the assigned expression.
function Plain() {}
Plain.foo = 1;
Plain.label = "plain";
const a: number = Plain.foo;
const b: string = Plain.label;
const bad1: string = Plain.foo; // TS2322

// A `const` initialized with an arrow/function expression is eligible too, and
// stays callable.
const Row = (p: { c?: number }) => p;
const Stats = (p: { x?: number }) => p;
Stats.Row = Row;
Stats.displayName = "Stats";
const c = Stats.Row({ c: 1 });
const d: string = Stats.displayName;
const e = Stats({ x: 1 });
// The property type is *widened*: `"Stats"`, not the literal.
const bad2: "Stats" = Stats.displayName; // TS2322

// Repeated assignments to one name all declare it; the type unions them.
function Two() {}
Two.p = 1;
Two.p = "s";
const f: string | number = Two.p;
const bad3: number = Two.p; // TS2322

// NEGATIVE: the target is not a function value, so this is an ordinary
// (failing) property write — `{}` has no `x`.
const obj = {};
obj.x = 1; // TS2339
const bad4 = obj.x; // TS2339

// NEGATIVE: a class is not expando-eligible.
class C {}
C.sx = 1; // TS2339

// NEGATIVE: `let` is not expando-eligible (only `const`).
let g = function () {};
g.h = 2; // TS2339

// NEGATIVE: a compound assignment declares nothing.
function Comp() {}
Comp.n += 1; // TS2339

// NEGATIVE: the assignment must be in the same scope as the declaration.
function Nested() {}
function wrap() {
  Nested.deep = 1; // TS2339
}
const bad5 = Nested.deep; // TS2339

export { a, b, bad1, c, d, e, bad2, f, bad3, bad4, bad5, g, wrap };
