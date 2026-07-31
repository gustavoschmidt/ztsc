// An element access whose index is a *stable identifier* is a narrowable
// reference: tsc's `isMatchingReference` matches two element accesses spelled
// with the same identifier when its symbol is a `const`, or a parameter /
// mutable local that is never assigned.
declare const m: Record<string, string | undefined>;
declare const k: string;

export function a(): string {
  if (m[k]) {
    return m[k];
  }
  return '';
}

// a parameter index
export function b(xs: (string | undefined)[], i: number): string {
  if (xs[i]) {
    return xs[i];
  }
  return '';
}

// a never-assigned local `let`
export function c(xs: (string | undefined)[]): string {
  let j = 0;
  if (xs[j]) {
    return xs[j];
  }
  return '';
}

// an optional-chain read guards the same access
export function d(mm: Record<string, string | undefined> | undefined, key: string): string {
  if (mm?.[key]) {
    return mm[key];
  }
  return '';
}

// any guard form applies, not just truthiness
export function e(rec: Record<string, string | number>, key: string): number {
  if (typeof rec[key] === 'number') {
    return rec[key];
  }
  return 0;
}

// the container is itself a property path
declare const box: { by: Record<string, string | undefined> };
export function f(key: string): string {
  if (box.by[key]) {
    return box.by[key];
  }
  return '';
}
