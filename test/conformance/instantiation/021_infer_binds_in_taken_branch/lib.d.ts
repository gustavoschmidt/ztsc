// Negative control for the alias-param-shadow fix (020): a live outer `infer`
// must stay visible even when a referenced alias's own param shares its name.
// `Elem<T>` captures `infer V` in the TAKEN (array) branch and threads it as the
// type ARGUMENT to `Wrap<V>`, whose own param is ALSO named `V`. The shadow only
// hides `Wrap`'s OWN `V` inside `Wrap`'s body — the argument `V` was resolved in
// `Elem`'s scope before entering `Wrap`, so it must still bind to the element
// type. A blanket clear of infer scopes on every alias reference would break
// this. Green before and after the fix.
export type Wrap<V> = { v: V };
export type Elem<T> = T extends ReadonlyArray<infer V> ? Wrap<V> : never;
