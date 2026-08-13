// `keyof` over a recursive conditional alias. Two separate ways this ran the
// stack out, both in `keyofType`'s union arm:
//
//   * the alias resolves to a union that lists the alias ITSELF among its
//     constituents, and the arm asks each constituent for its key set — so the
//     walk came straight back on the same type. `keyof_stack` closes that one
//     exactly.
//   * type-level arithmetic (tuple-recursive `Add`/`Concat` shapes) where each
//     lap expands the alias into a FRESH type, so nothing repeats and no
//     visited set can close it. Each expansion is a new top-level
//     instantiation, and `instantiateId` resets `inst_depth` at every entry,
//     so the instantiation budget never accumulated across the laps either.
//     `max_keyof_depth` closes that one.
//
// Both answer `unreadableKeySet` — the same deferral an operand gets while its
// structure is still materializing — so no key set is invented. The oracle
// checks this file clean, and so must ztsc: the bound must not fire on the
// shallow, terminating uses below.

// Self-referential through a conditional: the false branch is the alias.
type SelfUnion<T> = T extends string ? { s: T } : SelfUnion<T> | { n: number };

// Tuple-recursive concatenation, the shape that grows a fresh type per lap.
type Concat<A extends unknown[], B extends unknown[]> = A extends [infer H, ...infer R]
    ? Concat<R, [...B, H]>
    : B;

type Keys<T> = keyof T;

// Shallow, terminating uses: these must keep their exact key sets.
type K1 = Keys<{ a: 1; b: 2 }>;
type K2 = Keys<{ a: 1 } | { a: 2; b: 3 }>;
type K3 = Keys<Concat<[1, 2], [3]>[number] extends number ? { ok: true } : { no: true }>;
type K4 = Keys<SelfUnion<string>>;

export const k1: K1 = "a";
export const k2: K2 = "a";
export const k3: K3 = "ok";
export const k4: K4 = "s";
