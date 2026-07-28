// A hand-written declaration for a JS-only dependency — the `global.d.ts`
// idiom every app that depends on an untyped package ships.
declare module "png-lite" {
  function decode(input: string): number;
  export = decode;
}
