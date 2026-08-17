// Negative controls for the `switch (typeof x)` exclusion chain.

declare function assertNever(x: never): void;

// The chain runs FORWARD only: a label repeated LATER does not narrow the
// earlier clause, which still holds its own label's type.
export function laterDuplicateDoesNotNarrow(x: string | number | boolean) {
  switch (typeof x) {
    case "number":
      assertNever(x);
      return 0;
    case "boolean":
      return 1;
    case "number":
      return 2;
  }
}

// A `case` label that is not a string literal empties tsc's witness list, and
// then NO clause of the switch narrows at all — not even the ones with a
// perfectly good literal label.
declare const computed: string;
export function nonLiteralLabelDisablesTheSwitch(x: string | number) {
  switch (typeof x) {
    case computed:
      return 0;
    case "number": {
      const still: string | number = x;
      return still;
    }
    default: {
      const alsoStill: string | number = x;
      return alsoStill;
    }
  }
}

// The fall-out edge of a switch that does NOT cover the domain keeps the rest.
export function partialSwitchKeepsTheRest(x: string | number | boolean) {
  switch (typeof x) {
    case "string":
      return 0;
  }
  assertNever(x);
  return 1;
}

// `default:` narrows nothing when the discriminant is not the reference.
export function unrelatedDiscriminant(x: string | number, k: string) {
  switch (typeof k) {
    case "string":
      return 0;
    default: {
      const same: string | number = x;
      return same;
    }
  }
}
