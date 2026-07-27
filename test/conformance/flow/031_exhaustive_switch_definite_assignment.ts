// A `default`-less switch that covers every member of a literal-union
// discriminant cannot fall out of its clause list, so a variable assigned in
// every clause is definitely assigned afterwards. The binder always emits the
// "no clause matched" edge (exhaustiveness is a type question); the checker
// drops it when the switch is exhaustive.
type Dir = "up" | "down" | "left" | "right";

export function f(d: Dir) {
  let x: number;
  switch (d) {
    case "up": {
      x = 1;
      break;
    }
    case "down": {
      x = 2;
      break;
    }
    case "left": {
      x = 3;
      break;
    }
    case "right": {
      x = 4;
      break;
    }
  }
  return x;
}

// A MISSING member leaves the edge live: still TS2454.
export function partial(d: Dir) {
  let x: number;
  switch (d) {
    case "up": {
      x = 1;
      break;
    }
    case "down": {
      x = 2;
      break;
    }
    case "left": {
      x = 3;
      break;
    }
  }
  return x;
}

// A non-literal discriminant is never exhaustive without a `default`.
export function wide(n: number) {
  let x: number;
  switch (n) {
    case 0: {
      x = 1;
      break;
    }
    case 1: {
      x = 2;
      break;
    }
  }
  return x;
}

// A clause that does NOT assign still leaves the variable indefinite even when
// the switch is exhaustive.
export function gap(d: Dir) {
  let x: number;
  switch (d) {
    case "up": {
      x = 1;
      break;
    }
    case "down": {
      x = 2;
      break;
    }
    case "left": {
      break;
    }
    case "right": {
      x = 4;
      break;
    }
  }
  return x;
}

// `switch (typeof v)` over the full outcome set is exhaustive too.
export function byTypeof(v: string | number) {
  let x: number;
  switch (typeof v) {
    case "string": {
      x = v.length;
      break;
    }
    case "number": {
      x = v;
      break;
    }
  }
  return x;
}

// The narrowed type after an exhaustive switch that assigns in every clause is
// the union of what the clauses assigned — not `number | undefined`.
export function narrowed(d: Dir) {
  let x: 1 | 2 | 3 | 4;
  switch (d) {
    case "up": {
      x = 1;
      break;
    }
    case "down": {
      x = 2;
      break;
    }
    case "left": {
      x = 3;
      break;
    }
    case "right": {
      x = 4;
      break;
    }
  }
  const bad: 1 | 2 = x;
  return bad;
}
