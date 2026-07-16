// `noImplicitAny: false` suppresses the implicit-any family (TS7006 here).
// Every unannotated, uncontextual param below would be TS7006 under strict's
// default; with the option off they silently type as `any`, so the deep member
// accesses are allowed and nothing cascades. Oracle (tsgo) is generated with
// `--noImplicitAny false`, so the snapshot is clean and stays a differential.

export function f(x) {
  return x.anything.at.all;
}

export const g = (a, b) => a + b;

export function h(cb) {
  return cb(1, 2, 3);
}

// A contextually-typed param is fine regardless of the option — no regression.
export const typed: (n: number) => number = (n) => n + 1;
