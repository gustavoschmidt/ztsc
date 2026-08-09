// tsc's EXPORT CONTEXT: a declaration file whose top level holds no export
// DECLARATION (`export {…}` / `export * from` / `export =`) implicitly
// exports every top-level declaration, `export` modifier or not. Only an
// alias (a plain `import`) is exempt. React Native's `Appearance.d.ts` ships
// `ColorSchemeName` exactly this way.
import { Helper } from "./helper";

type Hidden = "light" | "dark";

interface HiddenShape {
    tone: Hidden;
}

declare function pick(h: Helper): Hidden;

export declare const shape: HiddenShape;
