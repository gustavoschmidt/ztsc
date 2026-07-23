// An OPTIONAL discriminant read `x?.k === lit` short-circuits to `undefined`
// when `x` is nullish, so the equality forces the receiver non-nullish on the
// asserting branch (tsc's optional-chain containment) IN ADDITION to filtering
// the union by the discriminant. Before the fix the discriminant filter kept
// `undefined` (a member without the `k` prop is conservatively kept), so
// `action.pin` spuriously reported TS18048.
type Action =
  | { kind: 'a'; pin: string }
  | { kind: 'b'; reason: string };

declare const found: Action | undefined;

function pinOf(): string | undefined {
  // True branch: `undefined` removed AND narrowed to the `'a'` member, so
  // `.pin` is clean.
  return found?.kind === 'a' ? found.pin : undefined;
}

// The `!==` form: the true branch does NOT imply the receiver is defined, so
// `found` stays possibly-undefined there (negative control).
function reasonOf(): string | undefined {
  if (found?.kind !== 'b') return undefined;
  // Here `found.kind === 'b'` holds, so `found` is the `'b'` member (undefined
  // removed): `.reason` is clean.
  return found.reason;
}

// NEG CONTROL: `x?.k === undefined` is true when `x` is undefined, so the
// receiver must NOT be narrowed non-null — `found.pin` stays an error.
function bad(): string {
  if (found?.kind === undefined) {
    return found.pin; // TS18048: 'found' is possibly 'undefined'
  }
  return '';
}
