// keyof T where T is a generic type param stays deferred, resolves on
// instantiation (M16d). keyof T is assignable to string | number | symbol.
function keysAsKey<T>(): keyof T { return null as any; }
type K<T> = keyof T;
type KP = K<{ a: 1; b: 2 }>;
const k1: "a" | "b" = null as any as KP;
const kbad: "a" = null as any as KP;   // TS2322 ("a" | "b" not "a")

function propKey<T>(k: keyof T): string | number | symbol { return k; }
