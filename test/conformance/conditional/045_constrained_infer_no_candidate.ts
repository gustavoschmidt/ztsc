// tsc's `getInferredType` constraint fallback: an `infer V extends C` binder
// that collects NO candidate infers `unknown`, which satisfies nothing but
// `unknown`, so the inferred type becomes `C` itself. Leaving it `unknown`
// made the constraint check read false and the conditional take its FALSE
// branch even though the check type matched the pattern.
//
// A binder inside an OPTIONAL property is where that happens: a check type
// that simply does not declare the property still matches, and there is
// nothing to infer from.

type Rec = { [_ in string]: unknown };

// No `$type` property is DECLARED (only an index signature), so `T` has no
// candidate and falls back to `"x"`.
type Q1 = Rec extends { $type?: infer T extends "x" } ? ["T", T] : ["no"];
declare const q1: Q1;
export const u1: ["T", "x"] = q1;

// An unconstrained binder keeps `unknown` — there is no constraint to fall
// back to.
type Q2 = Rec extends { $type?: infer T } ? ["T", T] : ["no"];
declare const q2: Q2;
export const u2: ["T", unknown] = q2;

// A candidate that DOES satisfy the constraint still wins over it.
type Q3<V> = V extends { $type?: infer T extends "x" | "y" } ? T : "no";
declare const q3: Q3<{ $type: "y" }>;
export const u3: "y" = q3;

// A candidate that does NOT satisfy the constraint still takes the false
// branch — the fallback is for the no-candidate case only.
declare const q4: Q3<{ $type: "z" }>;
export const u4: "no" = q4;

// The atproto shape: the fallback is what lets a bag-of-unknowns record
// narrow through the generated `is*` predicate instead of collapsing to
// `never`.
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

interface Post {
  $type: "app.bsky.feed.post";
  reply?: { root: string };
  [k: string]: unknown;
}
declare function isPost<V>(v: V): v is Typed<V, "app.bsky.feed.post", "main">;
declare const view: { record: Rec };

export function f() {
  if (!isPost(view.record)) return undefined;
  return view.record.reply;
}

// A DIFFERENT lexicon id still takes the false branch.
declare const other: { $type: "app.bsky.feed.like"; ok: boolean };
export function g() {
  if (isPost(other)) {
    const dead: never = other;
    return dead;
  }
  return other.ok;
}

// NEGATIVES — the fallback must not leave the binder at `unknown`, must not
// reach an unconstrained binder, and must not turn a false branch true.
export const bad1: ["T", "y"] = q1;
export const bad2: ["T", "x"] = q2;
export const bad3: "y" = q4;
