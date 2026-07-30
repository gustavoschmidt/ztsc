// Negatives for the computed-key contextual index lookup (see
// 037_computed_key_union_context.ts). Mapping over the contextual type must not
// make the value ANY literal that fits — the index type still has to admit it,
// and a context with no index signature must still give none.
type Ids = { [id: string]: true };
declare const k: string;

// The literal does not match the contextual index type.
export const a: Ids | undefined = { [k]: false };
export const b: Ids & { extra?: number } = { [k]: 1 };

// Neither constituent of the union context admits it.
export const c: { [id: string]: true } | { [id: string]: 1 } = { [k]: 2 };

// A union context whose constituents have NO index signature must give the
// member no contextual type — the mapping may not invent one.
export const d: string | undefined = { [k]: true };

// A numeric index context does not type a string-keyed computed member.
export const e: { [n: number]: 1 } | undefined = { [k]: 1 };

// The index type is admitted but a required named property is missing.
export const f: (Ids & { extra: number }) | undefined = { [k]: true };
