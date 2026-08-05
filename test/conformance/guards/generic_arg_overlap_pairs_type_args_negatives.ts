// The negative control for `generic_arg_overlap_pairs_type_args.ts`: pairing
// the type arguments must not turn the overlap test into a blanket yes.

interface Box<T> {
  v: T;
}

declare const bLit: Box<'a' | 'b'>;
declare const bZ: Box<'z'>;

// Two instantiations of one generic whose arguments do NOT overlap.
export const n1 = bLit === bZ;

// Different generics with the same argument do not pair.
interface Other<T> {
  w: T;
}
declare const oA: Other<'a'>;
declare const bA: Box<'a'>;
export const n3 = oA === bA;

export {};
