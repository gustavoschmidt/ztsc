// `implements` is checked against the MERGED instance type, so a member the
// interface half inherits satisfies the clause; TS2420 is anchored at the
// class NAME, not at the heritage reference that failed.
// (A class failing TWO clauses reports twice on the same name in tsc; ztsc's
// diagnostics dedupe on file+code+span start, so only the first survives.
// Not exercised here — the pair is indistinguishable at the file:line:col:code
// granularity every consumer scores by.)
interface Wrap {
  getSQL(): number;
}

// Satisfied only through the interface half's `extends`.
interface Ok extends Wrap {
}
declare class Ok implements Wrap {
  readonly n: number;
}

// The interface half supplies something else, so the clause still fails.
interface Bad {
  m2(): number;
}
declare class Bad implements Wrap {
  readonly q: number;
}

// No interface half at all.
declare class Plain implements Wrap {
  readonly z: number;
}
