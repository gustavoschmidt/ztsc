// The pre-`exports` idiom for publishing a deep import: `mathpkg/Sub` is a
// directory holding nothing but a package.json, whose entry fields point back
// *out* of it with `../` (fp-ts, io-ts and rxjs-compat all ship this shape).
// The subpath itself names no file and no `index`, so resolution has to read
// that directory package.json and follow the parent-escaping target.
import { sub } from "mathpkg/Sub";
import { idx } from "mathpkg";

const n: number = sub(1, 2);
const m: number = idx(3);
const bad: string = sub(1, 2); // TS2322 — sub returns number, so it resolved

export { n, m, bad };
