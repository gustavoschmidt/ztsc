import L from "./lib";
import * as NS from "./lib";

// `keyof typeof <export = namespace>` is the namespace's member names, not
// `never` — through a default import, a namespace import, and the type-position
// `import()` alike.
const a: "useRef" | "version" = null as any as keyof typeof L;
const b: "useRef" | "version" = null as any as keyof typeof NS;
const c: "useRef" | "version" = null as any as keyof typeof import("./lib");

// A key set that is not `never` still constrains.
function pick<K extends keyof typeof L>(k: K): K {
  return k;
}
const d = pick("version");

// Negative controls: a wrong key, and a key the namespace does not have.
const bad: "useRef" = null as any as keyof typeof L;
const nope = pick("absent");

export { a, b, c, d, bad, nope };
