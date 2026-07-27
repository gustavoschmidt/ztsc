export {};
// An enum member *access* is a widening (fresh) literal, exactly like a string
// literal: it widens to the whole enum at a mutable position and is kept by a
// `const` or by a member-typed context.
enum WS {
  A = "a",
  B = "b",
}
enum N {
  P = 1,
  Q = 2,
}

// `let` widens to the enum, so a sibling can be assigned later.
let l1 = WS.A;
l1 = WS.B;
let n1 = N.P;
n1 = N.Q;

// `const` keeps the member.
const c1 = WS.A;
const c2: WS.A = c1;

// An object-literal property widens (mutable position) ...
const o1 = { k: WS.A };
o1.k = WS.B;
const o2 = { k: c1 };
o2.k = WS.B;
// ... unless the context asks for the member.
const o3: { k: WS.A } = { k: WS.A };
const arr1: WS.A[] = [WS.A];
const arr2: WS[] = [WS.A, WS.B];

// An inferred return type widens.
function r1() {
  return WS.A;
}
const rr: WS = r1();

// NEGATIVE: the widened forms are not the member.
const bad1: WS.A = l1;
const bad2: WS.A = o1.k;
const bad3: WS.A = r1();
// NEGATIVE: the kept forms are not a sibling.
const bad4: WS.B = c1;
const bad5: WS.B = o3.k;
const bad6: WS.B = arr1[0];
