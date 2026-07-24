// An array/tuple relates to a target STRING index signature by its whole
// apparent type — every property (`length: number`, the `Array.prototype`
// methods, and the elements) must conform to the index type. Only an
// `any`/`unknown` index absorbs the function-typed methods and numeric
// `length`, so an array satisfies `{ [k: string]: any }` (and `unknown`) but
// NOT a concrete index like `{ [k: string]: string }`. Mirrors the dogfood
// project's `LayerInfo` ({ …optional props; [key: string]: any }), which
// absorbs an `AxiosResponse`-derived array / tuple.

interface LayerInfo {
  a?: number;
  [key: string]: any;
}
const ok1: LayerInfo = [1, 2, 3]; // number[] -> any index: ok
const ok2: LayerInfo = [{ k: "v" }]; // object[] -> any index: ok
const ok3: { [k: string]: unknown } = ["x", "y"]; // unknown index: ok
const ok4: { [k: string]: unknown } = [1, "y"] as [number, string]; // tuple -> unknown: ok

// a concrete (non-any/unknown) index does NOT admit an array/tuple: its
// methods and `length` are not assignable to the index type.
const bad1: { [k: string]: string } = ["x", "y"];
const bad2: { [k: string]: number } = [1, 2, 3];
const bad3: { [k: string]: string } = [1, "y"] as [number, string];
