// A QUOTED module name declares an EXTERNAL module, which only an ambient
// declaration may do: `module "M" { }` on its own is TS1035, while the same
// declaration behind `declare` is fine and so is one nested in an ambient
// module (the enclosing `declare` reaches it).
module "NotAmbient" {
  export const a = 1;
}

declare module "Ambient" {
  export const b: number;
  module "NestedIsAmbientToo" {
    export const c: number;
  }
}
