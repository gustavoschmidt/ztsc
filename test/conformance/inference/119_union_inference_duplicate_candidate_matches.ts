// tsc's `inferToMultipleTypes` bookkeeping: inferring a union source to a
// union target runs every NON-variable target constituent against every
// source constituent and records which sources produced an inference; the
// single naked type variable then receives the union of the sources that
// produced NONE. "Produced an inference" is about the inference happening,
// not about the candidate set CHANGING — a second constituent that infers
// the same type as the first has still matched its source.
//
// React Native's `StyleProp<T>` is the shape that tells them apart: the
// array member infers `T` first, so the brand member re-inferring the same
// `T` left the candidate untouched, its source constituent counted as
// unmatched, and the naked `T` swallowed the brand.

type Falsy = undefined | null | false | "";
type Brand<T> = number & { __brand: T };
interface RecursiveArray<T>
  extends Array<T | ReadonlyArray<T> | RecursiveArray<T>> {}
type StyleProp<T> =
  | T
  | Brand<T>
  | RecursiveArray<T | Brand<T> | Falsy>
  | Falsy;

interface TextStyle {
  fontSize?: number;
  color?: string;
}

declare function flatten<T>(style?: StyleProp<T>): T extends (infer U)[]
  ? U
  : T;

declare const styles: StyleProp<TextStyle>;

// `T` is `TextStyle`, so the flattened style has the style's properties.
export function f() {
  const s = flatten(styles) ?? {};
  const n: number | undefined = s.fontSize;
  const c: string | undefined = s.color;
  return [n, c];
}

// The brand must not survive into the inferred `T`.
export const bad: Brand<TextStyle> = flatten(styles);

// Reduced: two inference-bearing members that infer the SAME type.
declare function g<T>(x: T | Brand<T> | Array<T | Brand<T>>): T;
declare const v: TextStyle | Brand<TextStyle> | Array<TextStyle | Brand<TextStyle>>;
export const bad2: Brand<TextStyle> = g(v);

// A source constituent that genuinely matches NO wrapper still lands on the
// naked variable.
declare function h<T>(x: T | Brand<T>): T;
declare const w: TextStyle | Brand<TextStyle> | { extra: 1 };
export const both: TextStyle | { extra: 1 } = h(w);
