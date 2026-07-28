// A return-value mismatch is anchored at the RETURN STATEMENT, not at the
// returned expression. tsc's `checkReturnStatement` passes the statement as
// the error node, so the column is `return`'s — seven characters left of where
// ztsc used to point. The bare-`return` arm of the same function already
// anchored this way; only the value arm did not.
//
// The conformance runner compares (code, line), and a return expression always
// starts on the `return` keyword's own line (ASI sees to that), so this case
// cannot observe the column. It pins the diagnostic SET; the column is what
// bench/convergence.sh keys on, and moving it is what makes
// subset-shared.chunk.ts line up with the oracle there.

declare const s: string;

export function annotated(): number {
  return s;
}

export function conditional(flag: boolean): number {
  if (flag) {
    return s;
  }
  return 1;
}

// Async: the awaited value is what is related, and the anchor is the same.
export async function asyncAnnotated(): Promise<number> {
  return s;
}

// An arrow with a block body and an annotation.
export const arrow = (): number => {
  return s;
};

// A bare `return` where the annotation forbids it — the arm that was already
// anchored at the statement.
export function bare(): number {
  return;
}

// Correct returns stay silent, so the case is not just "everything errors".
export function ok(): string {
  return s;
}

export function okVoid(): void {
  return;
}
