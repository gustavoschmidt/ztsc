// `scriptkit`'s package.json has a `"types"` key — inside `"scripts"`, where
// it is a build command, not a declaration path. Only the ROOT object's keys
// are entry fields, so the declaration entry is the top-level `"typings"`.
import { run } from "scriptkit";

const n: number = run("build");
const s: string = run("build"); // TS2322 — run returns number, so it resolved

export { n, s };
