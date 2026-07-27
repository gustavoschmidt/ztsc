// A mapped type whose key set is still generic has no members to walk, so the
// relation needs rules of its own. Without them every generic helper written
// against `Mutable<T>` / `Readonly<T>` reported a phantom TS2322/TS2345, and a
// property read off one reported TS2339.
type Base = { readonly a: number; readonly b: string };

type Mut<T> = { -readonly [P in keyof T]: T[P] };
type Mut2<T> = { -readonly [P in keyof T]: T[P] }; // identical text, distinct alias
type Same<T> = { [P in keyof T]: T[P] };
type Same2<T> = { [P in keyof T]: T[P] };
type Ro<T> = { readonly [P in keyof T]: T[P] };
type Part<T> = { [P in keyof T]?: T[P] };
type Strs<T> = { [P in keyof T]: string };

// same alias, same route
export const a = <T extends Base>(x: Mut<T>): Mut<T> => x;
// alias -> inline, identical modifier and body
export const b = <T extends Base>(x: Mut<T>): { -readonly [P in keyof T]: T[P] } => x;
// alias -> a different alias with identical text
export const c = <T extends Base>(x: Mut<T>): Mut2<T> => x;
// no-modifier alias -> no-modifier alias
export const d = <T extends Base>(x: Same<T>): Same2<T> => x;
// modifier mismatch only
export const e = <T extends Base>(x: Mut<T>): Ro<T> => x;
// the source type parameter itself -> a map over it
export const f = <T extends Base>(x: T): Ro<T> => x;
export const g = <T extends Base>(x: T): Mut<T> => x;
// a map over the parameter -> the parameter
export const h = <T extends Base>(x: Same<T>): T => x;
export const i = <T extends Base>(x: Ro<T>): T => x;

// property access through the source's constraint
export const j = <T extends Base>(x: Mut<T>) => {
  const n: number = x.a;
  return n;
};
export const k = <T extends Base>(x: Mut<T>) => x.nope; // TS2339

// NEGATIVE: a map that ADDS `?` is not the type it maps
export const l = <T extends Base>(x: Part<T>): T => x; // TS2322
export const m = <T extends Base>(x: Part<T>): Mut<T> => x; // TS2322

// NEGATIVE: a different template is a different type
export const n = <T extends Base>(x: Strs<T>): Mut<T> => x; // TS2322
export const o = <T extends Base>(x: Mut<T>): Strs<T> => x; // TS2322

// NEGATIVE: an unrelated target is still rejected
export const p = <T extends Base>(x: Mut<T>): number => x; // TS2322
