// A generic function type used as a mapped type's *value* branch declares its
// own type parameter whose name collides with the mapped key (`K`). Per tsc
// lexical scoping, the signature's own `<K>` shadows the enclosing mapped key
// inside the signature, so it stays a real type parameter — it must NOT be
// bound to the mapped key parameter.
//
// ztsc previously resolved a bare `K` to the mapped key before consulting the
// signature's own type parameters, so the inner `<K>`-generic function was
// mis-materialized with a `mapped_param` in place of its own `K`. That node is
// invisible to `containsTypeParam`, so signature-erasure silently no-oped and
// the signature failed to relate — an order-dependent structural break (it
// only triggered when a mapped key of the same name happened to be in scope at
// materialization time, e.g. the DOM `Element`/`HTMLElement` `addEventListener`
// overloads, whose `<K extends keyof …EventMap>` broke `HTMLElement <: Element`).
//
// Here `f` must be callable with any string and return that same string.
type Bad<T> = { [K in keyof T]: <K extends string>(x: K) => K };
type Sig = Bad<{ a: 0 }>["a"];
declare const f: Sig;
const r = f("hello");
const ok: "hello" = r;
