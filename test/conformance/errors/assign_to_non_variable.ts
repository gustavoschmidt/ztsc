// tsc's `checkIdentifier` refuses a write to a name that is not a VARIABLE by
// WHAT IT IS, in a fixed order — enum, class, namespace, function, import —
// before the readonly test that produces "because it is a constant". ztsc
// answered `errorType` (so no TS2322 cascade) but said nothing.
//
// Every write site is covered, because tsc's `getAssignmentTargetKind` walks
// up through parentheses, array literals and spreads: an assignment, an
// increment, a compound assignment, a `for…in`/`for…of` head, and a
// destructuring element all write their target.

export {};

enum E {
  A,
}
class C {}
namespace N {
  export const q = 1;
}
function fn() {}
const k = 1;

E = 1 as any;
C = 1 as any;
N = 1 as any;
fn = 1 as any;
k = 2;

(E) = 1 as any;
(C) = 1 as any;
(fn) = 1 as any;
(k) = 2;

E++;
C++;
fn++;
k++;

E += 1;
fn += 1;

for (E of []);
for (fn in {});
[E] = [1];
({ a: fn } = { a: 1 });

// Negative controls: a real variable takes every one of these.
let v = 0;
v = 1;
(v) = 2;
v++;
v += 1;
for (v of []);
[v] = [1];
({ a: v } = { a: 1 });
