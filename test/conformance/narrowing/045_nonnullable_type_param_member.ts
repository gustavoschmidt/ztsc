// NonNullable of a type parameter is `T & {}` (tsc's getNonNullableType).
// Narrowing a `T extends string | undefined` reference by a nullish guard
// yields `T & {}`, whose apparent members come from the constraint with
// null/undefined stripped — so `.length` (string) resolves. Mirrors the
// dogfood project's `if (debouncedInput == null || debouncedInput.length …)`.
// `.length` is resolved without lib.d.ts, so every access below is clean.

function afterGuard<T extends string | undefined>(x: T) {
  if (x == null) return;
  x.length; // x is T & {} -> string
}

function inDisjunction<T extends string | undefined>(x: T) {
  // second operand is evaluated only when `x == null` is false
  if (x == null || x.length < 3) return;
}

function withNull<T extends string | null>(x: T) {
  if (x == null) return;
  x.length;
}

// an effectively non-nullish constraint needs no `& {}`, still resolves
function alreadyNonNull<T extends string>(x: T) {
  x.length;
}
