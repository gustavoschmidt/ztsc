// A homomorphic map over `any` is `any` (not `{}`): property access and calls
// stay permissive. ztsc previously materialized `{}`, so arbitrary member
// access wrongly errored and the value was not callable.
type Id<T> = { [K in keyof T]: T[K] };
type R = Id<any>;
declare const r: R;
const x: number = r.anything;
const y: string = r.f();
