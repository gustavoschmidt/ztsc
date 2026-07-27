// A union parameter with a NAKED type-parameter arm still contextually types a
// function argument through its callable arm, and an earlier callback argument
// that only echoes the still-uninferred parameter back must not fix it to `any`.
// Each case pins the ARROW PARAMETER's type: a negative that only fires when
// the parameter really is `boolean` (an `any` parameter would swallow it).

declare function f<T>(d: T | ((s: boolean) => T)): T;

const a1 = f((x) => {
  const b: boolean = x;
  return b ? 1 : 2;
});
const a2 = f((x) => {
  const n: number = x; // TS2322 — x is boolean
  return n;
});

// an earlier callback argument that merely passes the placeholder through
declare function g<T>(get: (e: { k: T }) => T, def: T | ((sel: boolean) => T)): T;

const b1 = g(
  (e) => e.k,
  (sel) => {
    const b: boolean = sel;
    return b ? 1 : 2;
  },
);
const b2 = g(
  (e) => e.k,
  (sel) => {
    const n: number = sel; // TS2322 — sel is boolean
    return n;
  },
);

// the same shape with the union arm first
declare function g2<T>(def: T | ((sel: boolean) => T), get: (e: { k: T }) => T): T;
const c1 = g2(
  (sel) => {
    const n: number = sel; // TS2322 — sel is boolean
    return n;
  },
  (e) => e.k,
);

// control: a callback that GENUINELY returns `any` still infers `any`
declare const anyv: any;
declare function h<T>(cb: () => T): T;
const d1: number = h(() => anyv);
const d2: string = h(() => anyv);

// control: a union WITHOUT a naked arm is unchanged
declare function k<T>(d: string | ((s: boolean) => T)): T;
const e1 = k((x) => {
  const n: number = x; // TS2322 — x is boolean
  return n;
});
const e2: string = k((x) => 1); // TS2322 — T is number

export { a1, a2, b1, b2, c1, d1, d2, e1, e2 };
