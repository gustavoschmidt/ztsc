// tsc's `getAdjustedTypeWithFacts(t, NEUndefinedOrNull)` is a `mapType`: the
// `NonNullable<…>` instantiation is applied constituent by constituent. ztsc
// applied its `T & {}` marker only when the WHOLE type was a bare type
// parameter and otherwise filtered a union by KIND, which leaves a type
// parameter untouched — so the marker was lost the moment a guard turned the
// parameter into a union.
//
// immich's `validate<T>(value: T): NonNullable<T> | null` is the shape: after
// `typeof value === 'number' && …` the reference is `number & T | T`, and its
// own `return value ?? null` was TS2322 against its own annotation.

declare function pick(): number;

export function nullishAfterAGuard<T>(value: T): (T & {}) | null {
  if (typeof value === "number" && value < 0) {
    return null;
  }
  return value ?? null;
}

// The bare parameter — the case that already worked, kept as the reference
// point for the one above.
export function nullishOnABareParam<T>(value: T): (T & {}) | null {
  return value ?? null;
}

// The non-null assertion and `!= null` reach the same strip.
export function assertionAfterAGuard<T>(value: T): T & {} {
  if (typeof value === "number" && value < 0) {
    return value;
  }
  return value!;
}

export function comparisonAfterAGuard<T>(value: T): (T & {}) | null {
  if (typeof value === "number" && value < 0) {
    return null;
  }
  if (value != null) {
    return value;
  }
  return null;
}

// `void` still drops out of `??` alongside `undefined` and `null`.
export function voidDropsFromNullish(x: boolean | void) {
  const y: boolean = x ?? false;
  return y;
}

export function voidDropsBesideAParam<T>(x: T | void): (T & {}) | number {
  return x ?? pick();
}

// Negative control: `??` must not hide a genuine mismatch.
export function stillReportsAMismatch(x: string | null) {
  const y: number = x ?? "a";
  return y;
}

// Negative control: the marker is not a number, and the union with the
// fallback is still reported.
export function markerIsNotANumber<T>(x: T) {
  const y: number = x ?? 1;
  return y;
}
