// TS 4.8 constrained `infer`: `infer V extends C` only matches when the type
// inferred for V satisfies C — otherwise the conditional takes its FALSE
// branch. The parser used to consume the constraint and throw it away, so
// every such conditional took the TRUE branch unconditionally.

export type A1 = "x" extends infer T extends "x" ? T : false;
export type A2 = "y" extends infer T extends "x" ? T : false;
declare const a1: A1;
declare const a2: A2;
export const ua1: "x" = a1;
export const ua2: false = a2;

// the constraint is what discriminates, not the shape
type Pick1<V> = V extends { p?: infer T extends "x" } ? [T] : false;
declare const b1: Pick1<{ p?: "x" }>;
declare const b2: Pick1<{ p?: "y" }>;
export const ub1: ["x"] = b1;
export const ub2: false = b2;

// The atproto shape this was found through: the constraint is written in terms
// of the ALIAS's own type parameters, so it is only decidable once the use
// site supplies them — a constraint recorded at declaration time and consulted
// at reduction time can never answer it.
type Tag<Id extends string, Hash extends string> = Hash extends "main"
  ? Id
  : `${Id}#${Hash}`;
type Typed<V, Id extends string, Hash extends string> = V extends {
  $type: Tag<Id, Hash>;
}
  ? V
  : V extends { $type?: string }
    ? V extends { $type?: infer T extends Tag<Id, Hash> }
      ? V & { $type: T }
      : never
    : V & { $type: Tag<Id, Hash> };

interface Rec {
  $type?: "app.bsky.embed.record#view";
  record: number;
}
interface Img {
  $type?: "app.bsky.embed.images#view";
  images: number;
}

declare const c1: Typed<Img, "app.bsky.embed.record", "view">;
declare const c2: Typed<Rec, "app.bsky.embed.record", "view">;
export const uc1: never = c1;
export const uc2: { record: number } = c2;

// distributes over a union check, so the sibling members drop out
declare const c3: Typed<Rec | Img | undefined, "app.bsky.embed.record", "view">;
export const uc3: { record: number } = c3;

// and that is what makes the generated predicate narrow
declare function isRec<V>(
  v: V,
): v is Typed<V, "app.bsky.embed.record", "view">;
declare const e: Rec | Img | undefined;
export function f() {
  if (isRec(e)) return e.record;
  return 0;
}

// NEGATIVES — an unsatisfiable constraint must not silently pass, and a
// satisfied one must not silently fail.
export const bad1: ["y"] = b2;
export const bad2: false = b1;
