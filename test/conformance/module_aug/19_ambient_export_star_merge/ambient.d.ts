// One `.d.ts` holding a `declare module` per entry point plus a final block for
// the package root that `export *`s them all back in — `transformation-matrix`'s
// typings, verbatim in shape. The two `declare module "tmat"` blocks merge, so
// `Matrix` comes from the first and every function from the stars in the second.
type PointTuple = [number, number];

declare module "tmat" {
  type Matrix = { a: number; b: number };
  export { Matrix };
}

declare module "tmat/identity" {
  import { Matrix } from "tmat";
  export function identity(): Matrix;
}

declare module "tmat/translate" {
  import { Matrix } from "tmat";
  export function translate(tx: number, ty?: number): Matrix;
}

declare module "tmat/apply" {
  import { Matrix } from "tmat";
  export function applyToPoint(matrix: Matrix, point: PointTuple): PointTuple;
}

// A star of a star: the root reaches `compose` two hops away.
declare module "tmat/compose" {
  export * from "tmat/transform";
}

declare module "tmat/transform" {
  import { Matrix } from "tmat";
  export function compose(...matrices: Matrix[]): Matrix;
}

declare module "tmat" {
  export * from "tmat/identity";
  export * from "tmat/translate";
  export * from "tmat/apply";
  export * from "tmat/compose";
}
