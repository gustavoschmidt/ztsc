// Equality narrowing on a discriminant applies to a SINGLE (non-union) member
// too: once a discriminated union has been narrowed to one constituent, the
// false branch of `x.type === 'C'` on `{ type: 'C' }` is `never` (tsc). The
// exhaustive `if`-return chain below therefore leaves `error` as `never` at the
// tail assertion, exactly as tsc computes it.
type E = { type: 'A'; a: number } | { type: 'B'; b: string } | { type: 'C' };

function handle(error: E): number {
  if (error.type === 'A') {
    return error.a;
  }
  if (error.type === 'B') {
    return error.b.length;
  }
  if (error.type === 'C') {
    return 0;
  }
  const _exhaustive: never = error;
  return _exhaustive;
}

// A WIDE (non-unit) discriminant must NOT over-narrow: `ref.current !== s`,
// where `current: string`, keeps the object — a `string` is not a unit type,
// so the assignment back into `current` still typechecks (no phantom `never`).
function bump(ref: { current: string }, s: string) {
  if (ref.current !== s) {
    ref.current = s;
  }
}

handle({ type: 'C' });
bump({ current: '' }, 'x');
