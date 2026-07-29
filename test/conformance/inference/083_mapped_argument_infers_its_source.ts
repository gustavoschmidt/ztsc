// Two generic mapped types infer through their source (tsc's
// `inferFromObjectTypes` rule for a mapped source against a mapped target).
//
// A DEFERRED `Partial<T>` argument has no members to reverse-map, but it does
// name its own source: `create(deleted, inserted)` with both arguments typed
// `Partial<T>` must infer `create`'s own parameter as `T`, not leave it
// unbound and fall back to `unknown`.

declare function create<U>(deleted: Partial<U>, inserted: Partial<U>): U;
declare function createRO<U>(v: Readonly<U>): U;
declare function createPick<U, K extends keyof U>(v: Pick<U, K>): U;

export function calculate<T extends { tag: string }>(): T {
  const deleted = {} as Partial<T>;
  const inserted = {} as Partial<T>;
  const same: T = create(deleted, inserted);
  return same;
}

// The modifier still resolves through the same inference.
export function withModifier<T extends { tag: string }>(
  modifier: (p: Partial<T>) => Partial<T>,
): T {
  const deleted = {} as Partial<T>;
  return create(modifier(deleted), deleted);
}

// A different homomorphic map on both sides pairs the same way.
export function readonlyMap<T extends { tag: string }>(): T {
  const ro = {} as Readonly<T>;
  const same: T = createRO(ro);
  return same;
}

// Not homomorphic on the argument side: `Pick<T, K>` carries a key set, not a
// source, so this must NOT infer `U = T` off the mapped source.
export function pickArg<T extends { tag: string }>(): string {
  const p = {} as Pick<T, "tag">;
  const out = createPick(p);
  const bad: string = out; // TS2322: the inferred U is not a string
  return bad;
}
