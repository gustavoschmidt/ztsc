// `[infer H, ...infer R]` binds R to the REST TUPLE, not the first rest element
// (the pre-fix bug bound R to a single element). Head binds the leading element.
type RestOf<T extends any[]> = T extends [any, ...infer R] ? R : never;
type X = RestOf<[1, 2, 3]>; // [2, 3]
const okx: X = [2, 3];
const badx: X = [2]; // TS2322 — source [2] is missing an element
type Head<T extends any[]> = T extends [infer H, ...any[]] ? H : never;
type H = Head<[10, 20, 30]>; // 10
const okh: H = 10;
const badh: H = 20; // TS2322
export {};
