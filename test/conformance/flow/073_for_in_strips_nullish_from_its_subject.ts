// `for (const k in maybeUndefined)` is legal JS — enumerating `null`/
// `undefined` yields no keys — so tsc reports nothing on the header
// (`checkForInStatement` runs the right-hand side through
// `getNonNullableTypeIfNeeded`) and the BODY sees the subject non-nullish
// (`getTypeAtFlowAssignment`'s `for..in` arm, keyed off the loop's own key
// binding). outline's `Logger.warn(extra?: Extra)` is the shape.

type Extra = { [k: string]: number };
declare function use(x: number): void;

export function bodySeesNonNullish(extra?: Extra) {
  for (const key in extra) {
    use(extra[key]);
    const alias: Extra = extra;
    use(alias[key]);
  }
}

export function nullAsWellAsUndefined(extra: Extra | null) {
  for (const key in extra) {
    use(extra[key]);
  }
}

// After the loop the subject is back to its declared type.
export function afterTheLoopItIsOptionalAgain(extra?: Extra) {
  for (const key in extra) {
    use(extra[key]);
  }
  const alias: Extra = extra; // TS2322
  return alias;
}

// A definitely-defined subject is unaffected.
export function definedSubject(extra: Extra) {
  for (const key in extra) {
    use(extra[key]);
  }
}

// A PRIMITIVE right-hand side is still TS2407, and the message names the
// stripped type.
export function primitiveSubject(n?: number) {
  for (const key in n) {
    use(key.length);
  }
}

// Only the enumerated subject is narrowed, not an unrelated optional.
export function unrelatedNotNarrowed(extra?: Extra, other?: Extra) {
  for (const key in extra) {
    use(other[key]); // TS18048
  }
}

// The assignment form (`for (k in x)`) narrows nothing — tsc's rule reads a
// VariableDeclaration. (The binding carries an initializer only to keep an
// unrelated gap out of the case: ztsc reports TS2454 on a `for (k in …)`
// target declared without one, where the loop header is the assignment.)
export function assignmentFormDoesNotNarrow(extra?: Extra) {
  let key = "";
  for (key in extra) {
    use(extra[key]); // TS18048
  }
}
