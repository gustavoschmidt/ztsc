// Under strictNullChecks tsc narrows `unknown` as if it were the union
// `undefined | null | {}` (`unknownUnionType`) and re-spells the FULL union
// `unknown` afterwards (`recombineUnknownType`). So a guard that removes the
// nullish arms leaves `{}` — which carries `Object`'s apparent members —
// while a guard that removes nothing leaves `unknown` spelled as itself.
//
// `if (!e) return ''; e.toString()` on an `unknown` error value is the idiom
// that needs it; left as `unknown` it was a false TS2339.

export function truthy(e: unknown): string {
  if (!e) return "";
  return typeof e === "string" ? e : e.toString();
}

// The falsy branch removes nothing (an empty-object type can still be a
// falsy primitive), so it stays `unknown`.
export function falsyBranchIsUnknown(e: unknown): unknown {
  if (e) return "";
  const still: unknown = e;
  return still;
}

// One nullish arm at a time.
export function neqNull(e: unknown) {
  if (e !== null) {
    const partial: {} | undefined = e;
    return partial;
  }
  return undefined;
}

export function neqBoth(e: unknown) {
  if (e !== null && e !== undefined) {
    const nonNullish: {} = e;
    return nonNullish;
  }
  return undefined;
}

// `!` and `??` go through the same non-nullable rule.
export function bang(e: unknown): {} {
  return e!;
}

export function coalesce(e: unknown): {} | "fallback" {
  return e ?? "fallback";
}

// NEGATIVES — the narrowed type is `{}`, not a specific shape, and the
// falsy branch is not narrowed at all.
export function bad1(e: unknown) {
  if (!e) return 0;
  return e.length;
}

export function bad2(e: unknown) {
  if (!e) return 0;
  const shaped: { a: number } = e;
  return shaped;
}

export function bad3(e: unknown) {
  if (e) return 0;
  const stillUnknown: string = e;
  return stillUnknown;
}
