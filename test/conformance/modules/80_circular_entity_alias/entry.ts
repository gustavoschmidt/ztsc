// `import a = a.b` names itself: resolving the alias means resolving its own
// qualifier `a`, which is the alias again. tsc's `resolveAlias` cuts that
// recursion with its resolving-alias marker and reports TS2303 once.
import a = a.b;

// A qualified entity alias reaches its target THROUGH its leftmost identifier
// (`resolveEntityName` resolves the qualifier first), so a loop running
// through one is still a loop, and both declarations on it report.
import G = H.I;
import H = G;

// Being merely upstream of a cycle is not being on it: `A` and `B` define each
// other, but `X` is only defined BY them and reports nothing.
import A = B;
import B = A;
import X = A.foo;

// Depth is irrelevant: the edge leaves from the LEFTMOST identifier however
// deep the name is.
import d = d.b.c.e;
import R = S.x.y;
import S = R.z;

// A qualified alias whose qualifier chain is real resolves, and is not
// circular: nothing here reports.
namespace M {
    export namespace N {
        export interface I {}
    }
}
import P = M;
import Q = P.N;
declare const q: Q.I;
export { a, G, H, A, B, X, d, R, S, P, Q, q };
