// Reflexive assignability of a generic INTERFACE materialized through two
// distinct paths that must agree by identity:
//   - the annotation `Handle<Payload>` — ONE-step interface instantiation
//     (`expandRef` of `makeRef(Handle, [Payload])`);
//   - `open<Payload>()` — TWO-step: the pre-expanded signature-return object
//     `Handle<T>` re-instantiated with `T := Payload` at the call.
// A nested keyof/mapped/conditional inside a generic interface body can reduce
// non-confluently one-step vs two-step (the deep react-hook-form
// `UseFormReturn` shape), yielding structurally-distinct interned objects that
// then fail their own reflexive relation. Both builds are tagged with the
// canonical origin `makeRef(Handle, [Payload])`, so the relation short-circuits
// by identity regardless of any structural divergence.
interface Box<T> {
  get(): T;
  set(v: T): void;
}
interface Handle<T> {
  box: Box<T>;
  clone(): Box<T>;
}
declare function open<T>(): Handle<T>;

type Payload = { id: string; tags: string[] };

// One-step annotation vs two-step call return — reflexive, clean.
const h: Handle<Payload> = open<Payload>();

// The same across a method returning an interface-typed value.
const b: Box<Payload> = open<Payload>().clone();

// Negative control — the origin fast-path is IDENTITY-ONLY: it fires only when
// symbol AND args are equal. A different instantiation (`Handle<Other>`, whose
// `id` is `number`) must still be rejected; a symbol-only shortcut would wrongly
// accept it.
type Other = { id: number; tags: string[] };
const bad: Handle<Other> = open<Payload>(); // TS2322
