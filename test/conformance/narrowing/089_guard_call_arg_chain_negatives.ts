// Negatives for the type-predicate optional-chain arm: only the TRUE branch
// asserts anything, a predicate type that can itself be `undefined` asserts
// nothing, and the rule narrows the RECEIVER only — never the chain's result.
type Node2 = { child?: { value?: string | number } };
declare function isStr(x: unknown): x is string;

// false branch: the chain may well have short-circuited
export function a(n: Node2 | undefined): number {
  if (!isStr(n?.child?.value)) {
    return n.child ? 1 : 0; // error: 'n' is possibly 'undefined'
  }
  return 0;
}

// a predicate type that admits `undefined` cannot prove the chain ran
declare function isMaybeStr(x: unknown): x is string | undefined;

export function b(n: Node2 | undefined): number {
  if (isMaybeStr(n?.child?.value)) {
    return n.child ? 1 : 0; // error: 'n' is possibly 'undefined'
  }
  return 0;
}

// the receivers are non-nullish, but a reference OUTSIDE the chain is untouched
export function c(n: Node2 | undefined, m: Node2 | undefined): number {
  if (isStr(n?.child?.value)) {
    return m.child ? 1 : 0; // error: 'm' is possibly 'undefined'
  }
  return 0;
}

// an assertion signature narrows after the call, not inside the condition
declare function assertStr(x: unknown): asserts x is string;

export function d(n: Node2 | undefined): number {
  if (n && assertStr(n?.child?.value)) {
    return 1;
  }
  return n.child ? 1 : 0; // error: 'n' is possibly 'undefined'
}
