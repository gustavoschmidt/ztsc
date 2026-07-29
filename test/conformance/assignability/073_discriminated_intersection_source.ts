// Discriminated-union normalization accepts an INTERSECTION source, not just
// a plain object. `Merge<U, { type: K }>` is `Omit<U, "type"> & { type: K }` —
// the shape of every helper that re-tags a discriminated union — so the
// discriminant lives in a different constituent from the payload and the whole
// intersection has to be consulted.
type Merge<M, N> = Omit<M, keyof N> & N;

type Base = { id: string; x: number; y: number; isDeleted: boolean };
type Sel = Base & { type: "selection" };
type Rect = Base & { type: "rectangle" };
type Diam = Base & { type: "diamond" };
type Ell = Base & { type: "ellipse" };
type Generic = Sel | Rect | Diam | Ell;

type NonDeleted<T extends Generic> = T & { isDeleted: boolean };

declare const mk: <T extends Generic>(
  type: T["type"],
) => Merge<Generic, { type: T["type"] }>;

// The source's `type` is the whole `"selection" | "rectangle" | "diamond" |
// "ellipse"` union, so it matches no single target constituent — it spans them.
export const newElement = (opts: {
  type: Generic["type"];
}): NonDeleted<Generic> => mk<Generic>(opts.type);

// Negative: a discriminant constituent the target does not cover at all.
type Narrower = Sel | Rect;
declare const mk2: <T extends Generic>(
  type: T["type"],
) => Merge<Generic, { type: T["type"] }>;
export const tooWide = (opts: { type: Generic["type"] }): Narrower =>
  mk2<Generic>(opts.type);

// Negative: the discriminant spans the target, but a NON-discriminant property
// of the source does not fit.
type BadBase = { id: number; x: number; y: number; isDeleted: boolean };
declare const mk3: <T extends Generic>(
  type: T["type"],
) => Omit<BadBase, "type"> & { type: T["type"] };
export const badPayload = (opts: {
  type: Generic["type"];
}): NonDeleted<Generic> => mk3<Generic>(opts.type);
