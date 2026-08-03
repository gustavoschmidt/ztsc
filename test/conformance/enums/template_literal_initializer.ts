// A no-substitution template literal is a CONSTANT string enum initializer.
// tsc's `computeConstantValue` folds it to its cooked text, so `` E.B = `b` ``
// is indistinguishable from `E.A = 'a'` — same member value, same string
// domain, same nominal enum.
//
// Classifying it as "computed" instead made the member opaque and, worse,
// cost the whole enum its all-string classification: `switch` on a value of
// the enum then rejected every `case` label (TS2678), and no member related
// to `string` at all. immich's `ManualJobName` writes nine of its members in
// backticks, which is how this surfaced.

enum E {
  A = 'a',
  B = `b`,
  C = `c`,
}

declare const e: E;

switch (e) {
  case E.A: {
    break;
  }
  case E.B: {
    break;
  }
  case E.C: {
    break;
  }
}

// The member's value literal is visible: it widens to `string`, satisfies its
// own literal type, and nothing else.
const s: string = E.B;
const lit: 'b' = E.B;

// Comparable-relation reach (TS2367): a string equal to a member value
// overlaps the enum; one that is not, does not.
declare const raw: string;
const overlap = raw === E.B;

export { s, lit, overlap };

// A mixed enum still separates its domains, and auto-increment still stops
// after a string member.
enum M {
  N = 1,
  S = `s`,
  T = 'T',
}
const mn: number = M.N;
const ms: string = M.S;
const mt: 'T' = M.T;
export { mn, ms, mt };
