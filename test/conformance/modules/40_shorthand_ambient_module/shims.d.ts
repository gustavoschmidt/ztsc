// The *shorthand* ambient module form: no block at all. Every export of a
// matching specifier is `any`. Declarations that follow it in the same file
// must still bind — demanding a `{` here used to swallow the rest of the file
// through error recovery, silently dropping `Marker` (and, in a real project
// `global.d.ts`, every interface augmentation after the shim).
declare module "*.scss";

declare module "virtual:plain";

interface Marker {
  m: number;
}
