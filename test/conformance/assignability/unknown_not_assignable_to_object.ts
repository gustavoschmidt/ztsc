// `unknown` is the top type: tsc relates it to `any` and `unknown` and to
// nothing else. An ALL-OPTIONAL target (`{ a?: number }`, `Partial<T>`) and
// the empty object `{}` are no exception — a target every property of which
// may be absent still rejects a value whose shape is unknown.
declare const u: unknown;
declare let w1: { a?: number };
w1 = u;
declare let w2: { a?: number } | undefined;
w2 = u;
declare let w3: { a: number };
w3 = u;
declare let w4: {};
w4 = u;
declare let w5: Partial<{ a: number; b: string }>;
w5 = u;
declare let w6: Record<string, number>;
w6 = u;
// …and the shapes that DO accept it.
declare let ok1: unknown;
ok1 = u;
declare let ok2: any;
ok2 = u;
export { w1, w2, w3, w4, w5, w6, ok1, ok2 };
