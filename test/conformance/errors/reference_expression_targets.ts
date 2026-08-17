// tsc's `checkReferenceExpression`: every write target — an assignment's
// left-hand side, an increment operand, a `for…in`/`for…of` binding, a
// destructuring element — must be *classified as a reference*: an identifier
// or a property/element access once parentheses and assertions are skipped,
// and never an optional chain (a short-circuited chain has nowhere to write).
//
// Each site carries its own pair of codes: the "must be a variable or a
// property access" one and the optional-chain one. ztsc had none of them.

declare const obj: any;
declare function f(): number;
declare let n: number;
declare let s: string;

// TS2357 — increment operand.
f()++;
++f();
(1 + 2)++;

// TS2364 — assignment target.
f() = 1;
(1 + 2) = 3;

// TS2777 — increment through an optional chain. The flag rides the whole
// spine, so a link written after the `?.` is an optional chain too.
obj?.a++;
obj?.a.b++;
++obj?.a;

// TS2779 — assignment through an optional chain, compound and logical alike.
obj?.a = 1;
obj?.a.b = 1;
obj?.a += 1;
obj?.a ??= 1;

// TS2780 / TS2781 — loop bindings.
for (obj?.a in {});
for (obj?.a of []);

// TS2779 / TS2778 — destructuring elements, with the object-rest target
// spelling its own code.
({ a: obj?.a } = { a: 1 });
({ ...obj?.a } = { a: 1 });
[...obj?.a] = [];
[obj?.a] = [1];

// TS2487 — a `for…of` binding that is no reference at all.
for (f() of []);

// Negative controls: parentheses and assertions are skipped, so these name
// perfectly good references.
(n) = 1;
(n as number) = 2;
n! = 3;
(n)++;
obj.a = 1;
obj["a"] = 1;
for (s in {});
for (n of []);
({ a: n } = { a: 1 });
[n] = [1];

// An arithmetic operand that is rejected outright (TS2356) never reaches the
// reference check — tsc runs it only when the operand check succeeded.
declare let arr: number[];
--arr;
arr--;
