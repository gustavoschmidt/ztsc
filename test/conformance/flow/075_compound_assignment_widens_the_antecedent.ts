// A compound assignment (`+=`, `++`, `--`) is tsc's AssignmentKind.Compound:
// the reference afterwards is `getBaseTypeOfLiteralType` of the type it
// already had. It refines nothing and it invents nothing — it only drops
// literal-ness.
//
// Each fact is pinned from BOTH sides: the widened reading is accepted, and
// the narrower one it replaced is rejected. A snapshot records only the code
// and the line, so a one-sided probe would not tell `number` from `1 | 2`.

let y: 1 | 2 = 1;
y++;
const y_widened: number = y;
const y_not_literal: 1 | 2 = y; // TS2322 — the write dropped the literals

let z: 1 | 2 = 1;
z += 1;
const z_widened: number = z;
const z_not_literal: 1 | 2 = z; // TS2322

let s: "a" | "b" = "a";
s += "c";
const s_widened: string = s;
const s_not_literal: "a" | "b" = s; // TS2322

let e;
e = 1;
e += 1;
const e_widened: number = e;

let m: number | string = 1;
m += 1;
const m_widened: number = m;

// A LOGICAL assignment is DEFINITE, not compound: it still narrows.
let q: number | null = null;
q ??= 3;
const q_narrowed: number = q;

class C {
    p: number | undefined = 1;
    f() {
        // The write refines nothing, so the declared `| undefined` survives.
        this.p!++;
        const p_still_optional: number | undefined = this.p;
        const p_not_narrowed: number = this.p; // TS2322
    }
}
