// The condition's "reference candidate": an assignment expression stands in
// for its target and a comma expression for its right operand, so
// `while ((m = next()) !== null)` narrows `m` inside the loop.
declare function next(): { index: number } | null;
declare function num(): number | undefined;

let m: { index: number } | null = null;
while ((m = next()) !== null) {
  const a: number = m.index;
}

let p: { index: number } | null = null;
if ((p = next()) !== null) {
  const b: number = p.index;
}

// Truthiness form.
let q: { index: number } | null = null;
if ((q = next())) {
  const c: number = q.index;
}

// Negated / else branch.
let r: { index: number } | null = null;
if (!(r = next())) {
  const d: null = r;
} else {
  const e: number = r.index;
}

// Logical-assignment operators are reference candidates too.
let s: { index: number } | null = null;
if ((s ??= next()) !== null) {
  const f: number = s.index;
}
let t: { index: number } | null = null;
if ((t ||= next()) !== null) {
  const g: number = t.index;
}

// A comma expression is its right operand.
let u: { index: number } | null = null;
let side = 0;
if (((side = 1), (u = next())) !== null) {
  const h: number = u.index;
}

// Property paths work the same way.
const o: { v: { index: number } | null } = { v: null };
if ((o.v = next()) !== null) {
  const i: number = o.v.index;
}

// typeof over an assignment.
let w: number | undefined;
if (typeof (w = num()) === "number") {
  const j: number = w;
}

// do/while.
let x: { index: number } | null = null;
do {
  const k: { index: number } | null = x;
} while ((x = next()) !== null);
