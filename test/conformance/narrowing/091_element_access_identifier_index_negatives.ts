// Negatives: an identifier index only makes an element access a stable
// reference when the identifier itself is stable, and two accesses match only
// when they name the SAME symbol.

// an index that is assigned anywhere in its function is not stable
export function a(xs: (string | undefined)[]): string {
  let i = 0;
  if (xs[i]) {
    return xs[i]; // error: 'i' is assigned below, so xs[i] is not a reference
  }
  i = 1;
  return '';
}

// two different index symbols are two different references
export function b(xs: (string | undefined)[], i: number, j: number): string {
  if (xs[i]) {
    return xs[j]; // error: xs[j] was never guarded
  }
  return '';
}

// a computed index is not an identifier at all
export function c(xs: (string | undefined)[], i: number): string {
  if (xs[i + 0]) {
    return xs[i + 0]; // error: not a narrowable reference
  }
  return '';
}

// the guard narrows the ELEMENT, not the container
declare const m: Record<string, { v?: string } | undefined>;
export function d(k: string): string {
  if (m[k]) {
    return m[k].v; // error: 'v' is optional
  }
  return '';
}

// writing the element drops the narrowing
export function e(xs: (string | undefined)[], i: number): string {
  if (xs[i]) {
    xs[i] = undefined;
    return xs[i]; // error: assigned undefined
  }
  return '';
}
