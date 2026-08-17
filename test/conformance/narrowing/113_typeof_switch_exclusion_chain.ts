// tsc's `narrowTypeBySwitchOnTypeOf` narrows a `switch (typeof x)` clause
// against the labels of the clauses AROUND it, not just its own:
//
//   * `default:` — and the implicit "nothing matched" edge that falls out of a
//     `default`-less switch — keeps only what is not-equal to EVERY label.
//   * a `case` clause first excludes every label written BEFORE it, then
//     narrows to its own. That exclusion chain is why a repeated
//     `case 'number':` is `never` the second time around.
//
// ztsc narrowed a `case` clause by its own label alone and left `default:`
// (and the fall-out edge) completely unnarrowed.

declare function assertNever(x: never): void;

type Basic = string | number | boolean | symbol | object | undefined;

// `default:` subtracts every handled label.
export function explicitDefault(x: Basic) {
  switch (typeof x) {
    case "number":
      return 0;
    case "boolean":
      return 1;
    case "symbol":
      return 2;
    case "object":
      return 3;
    default: {
      const rest: string | undefined = x;
      return rest;
    }
  }
}

// The implicit fall-out edge of a `default`-less switch narrows identically.
export function implicitDefault(x: Basic) {
  switch (typeof x) {
    case "number":
      return 0;
    case "boolean":
      return 1;
    case "symbol":
      return 2;
    case "object":
      return 3;
  }
  const rest: string | undefined = x;
  return rest;
}

// A label repeated after the whole domain is covered is unreachable in the
// type system: the chain has already subtracted it.
export function repeatedLabelIsNever(x: string | number | boolean) {
  switch (typeof x) {
    case "string":
      return 0;
    case "number":
      return 1;
    case "boolean":
      return 2;
    case "number":
      assertNever(x);
      return 3;
  }
}

// A `default:` in the middle subtracts the labels written after it too, and a
// `case` after it still only subtracts the ones written before it.
export function defaultInTheMiddle(x: string | number | boolean | object) {
  switch (typeof x) {
    case "number":
      return 0;
    default: {
      const o: string | object = x;
      return o;
    }
    case "boolean": {
      const b: boolean | object = x;
      return b;
    }
  }
}

// Exhausting a boolean by its two literals leaves nothing on the fall-out edge.
export function exhaustedBoolean(x: true | false) {
  switch (x) {
    case true:
      return 0;
    case false:
      return 1;
  }
  assertNever(x);
  return 2;
}

// A fallthrough group is the union of its labels.
export function fallthroughGroup(x: string | number | boolean) {
  switch (typeof x) {
    case "string":
    case "number": {
      const sn: string | number = x;
      return sn;
    }
  }
  const b: boolean = x;
  return b;
}
