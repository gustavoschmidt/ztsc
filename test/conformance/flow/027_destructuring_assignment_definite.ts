// A destructuring ASSIGNMENT is a definite assignment of every target it
// writes, and its targets are writes — not reads — so neither the targets
// themselves nor later uses are "used before being assigned".
declare function pair(): [number, number];
declare function rec(): { a: number; b: number; nested: { c: number } };

let x: number, y: number;
[x, y] = pair();
const s: number = x + y;

let a: number, b: number;
({ a, b } = rec());
const t: number = a + b;

// Renamed keys: `a`/`b` are property names, not references.
let dx: number, dy: number;
({ a: dx, b: dy } = rec());
const u: number = dx + dy;

// Nested pattern.
let cc: number;
({ nested: { c: cc } } = rec());
const v: number = cc;

// Defaults, in both the array and the object cover grammar.
let p: number, q: number;
[p = 1, q = 2] = pair();
const w: number = p + q;
let r: number;
({ a: r = 3 } = rec());
const w2: number = r;

// Rest element.
let h: number, tail: number[];
[h, ...tail] = [1, 2, 3];
const w3: number = h + tail.length;

// Computed key.
const k = "a";
let ck: number;
({ [k]: ck } = rec());
const w4: number = ck;

// Elisions.
let z1: number, z2: number;
[z1, , z2] = [1, 2, 3];
const w5: number = z1 + z2;

// Member-expression targets.
const obj = { m: 0 };
[obj.m] = pair();
({ a: obj.m } = rec());

// A loop-carried destructuring assignment.
let lx: number, ly: number;
let i = 0;
while (i < 3) {
  [lx, ly] = pair();
  i = lx + ly;
}
