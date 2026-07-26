// An array/tuple carries no STRING index signature of its own, so it does not
// satisfy a target string index -- with one exception: a target index whose
// type is exactly `any` short-circuits the index-signature relation. `unknown`
// does NOT get that exemption (it is not `any`), so `{ [k: string]: unknown }`
// rejects an array just like `{ [k: string]: string }` does. Mirrors a real
// project's catch-all `{ ...optional props; [key: string]: any }`, which
// absorbs an HTTP-response-derived array.

interface LayerInfo {
  a?: number;
  [key: string]: any;
}
const ok1: LayerInfo = [1, 2, 3]; // number[] -> any index: ok
const ok2: LayerInfo = [{ k: "v" }]; // object[] -> any index: ok
const bad0: { [k: string]: unknown } = ["x", "y"]; // unknown index: NOT ok
const bad0b: { [k: string]: unknown } = [1, "y"] as [number, string]; // same

// a concrete (non-any) index does NOT admit an array/tuple: it has no string
// index signature to relate.
const bad1: { [k: string]: string } = ["x", "y"];
const bad2: { [k: string]: number } = [1, 2, 3];
const bad3: { [k: string]: string } = [1, "y"] as [number, string];
