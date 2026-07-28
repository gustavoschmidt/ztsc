import api from "eqlib";
import "eqlib-plugin";

// `Api` is not an export of "eqlib" — it is a member of the namespace the
// module exports with `export =`. Both augmentations of it must merge in.
const a: number = api.twice(1);
const b: number = api.thrice(1);

// Negative controls: the merge must not invent members, and the merged
// members keep their declared types.
const bad: string = api.twice(1);
const nope = api.missing(1);

export { a, b, bad, nope };
