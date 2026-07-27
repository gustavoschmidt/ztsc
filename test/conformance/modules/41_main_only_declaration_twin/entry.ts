// `iconkit` ships only `"main": "lib/index.js"` — no `types`, no `typings`,
// no `exports`. tsc still resolves it for a TypeScript program by substituting
// declaration extensions for the runtime one, so `lib/index.d.ts` next to the
// named `lib/index.js` is the entry (this is `allowJs`-independent: the
// declaration file is what is loaded, not the JS).
import { icon } from "iconkit";

const n: number = icon("x");
const s: string = icon("x"); // TS2322 — icon returns number, so it did resolve

export { n, s };
