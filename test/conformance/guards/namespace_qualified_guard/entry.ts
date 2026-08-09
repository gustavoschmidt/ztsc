// A type guard called through a NAMESPACE (`NS.isFoo(x)`) narrows exactly as
// the same function called directly does.
//
// `declaredPathTypeInner` — the read-only lookup the flow walk uses for a
// member callee, so that checking it cannot disturb narrowing state —
// resolved a symbol only when it was an explicitly-typed variable. A
// namespace import is not one, so the RECEIVER answered "no information",
// `guardCallOf` found no predicate, and nothing narrowed. Worse, it was
// order-dependent: an already-materialized symbol short-circuits that rule,
// so whether the guard fired depended on what the checker owning the file had
// happened to compute — a `--checkers`-sensitive divergence.
//
// tsc resolves a ValueModule outright (`getExplicitTypeOfSymbol`), which is
// safe for the same reason: a namespace object's type is a fact of the module
// graph, not an inference over a body.
//
// Every @atproto/api guard on the bluesky social-app is written this way
// (`ChatBskyConvoDefs.isGroupConvo(prev.kind)`).
import * as Star from "./defs.js";
import { Defs } from "./reexport.js";
import { isRec, type Rec, type Img } from "./defs.js";

declare const e: Rec | Img | undefined;

// direct call — the control
export function a() {
  if (isRec(e)) return e.record;
  return 0;
}

// `import * as NS`
export function b() {
  if (Star.isRec(e)) return e.record;
  return 0;
}

// a re-exported namespace (`export * as NS`)
export function c() {
  if (Defs.isRec(e)) return e.record;
  return 0;
}

// non-generic predicate through the namespace
export function d() {
  if (Star.isRecPlain(e)) return e.record;
  return 0;
}

// negated guard, so the narrowing has to survive the else branch
export function f() {
  if (!Star.isRec(e)) return 0;
  return e.record;
}

// assertion function through the namespace
export function g() {
  Star.assertRec(e);
  return e.record;
}

// NEGATIVES — a failed guard must not narrow, and a guard must not invent
// members neither constituent has.
export function h() {
  if (Star.isRec(e)) return e.images;
  return 0;
}
export function i() {
  if (Star.isRec(e)) return e.nope;
  return 0;
}
export function j() {
  return e.record;
}
