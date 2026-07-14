// A recursive JSON type alias checks real recursive data without collapsing
// to `any` or hanging (M16d). All values here are valid JSON — the case is
// clean under both tsc and ztsc (proves termination + acceptance).
type Json = string | number | boolean | null | Json[] | { [k: string]: Json };
const a: Json = { name: "ok", nested: { deep: [1, 2, { x: true }] }, z: null };
const b: Json = [1, "two", [3, [4, [5, null]]], { k: "v" }];
const c: Json = "scalar";
const d: Json = { list: [{ a: 1 }, { b: [true, false] }] };
