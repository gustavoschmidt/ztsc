// An ambient `declare module` describing a dependency that ships no types —
// the shape an app's `global.d.ts` uses for a JS-only package.
declare module "untyped-thing" {
  namespace Thing {
    interface Inst {
      go(n: number): string;
    }
    interface Static {
      (o?: number): Inst;
    }
  }
  const thing: Thing.Static;
  export = thing;
}
