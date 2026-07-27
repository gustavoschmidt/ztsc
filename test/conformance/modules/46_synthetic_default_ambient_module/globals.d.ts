// An ambient `declare module` block with real ES-style named exports and no
// default — the shape `@types/node` gives `fs`, `util`, `crypto`, … (`path` is
// `export =` instead, which reaches the export entity directly). An ambient
// block only ever appears in a declaration file, so the runtime shape is
// unknown and the synthesized default always applies.
declare module "namedonly" {
  export const value: number;
  export function helper(): string;
}

// A default import of a module that does have one is unaffected.
declare module "hasdefault" {
  const d: number;
  export default d;
}
