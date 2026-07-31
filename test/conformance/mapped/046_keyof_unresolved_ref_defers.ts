// `keyof` of a `.ref` that does not resolve to a structure is NOT `keyof any`.
// A SELF-recursive mapped alias whose body is still materializing resolves to
// `error` through the ref-expansion cycle cut; answering the full
// `string | number | symbol` domain baked that answer into whatever composite
// was being built. react-hook-form's `Merge<A, B>` interned
// `keyof A & keyof B` as `("message" | "type") & (string | number | symbol)`,
// so EVERY key took the "present in both" branch and `FieldErrors<T>[k]` came
// out with `unknown`-typed members.
//
// The tell is that `R` (self-recursive) and `S` (identical body, recursion
// routed through a twin alias) must denote the same type.

type FE = { type: string; message?: string };

type Merge<A, B> = {
  [K in keyof A | keyof B]?: K extends keyof A & keyof B
    ? B[K]
    : K extends keyof A
      ? A[K]
      : K extends keyof B
        ? B[K]
        : never;
};

// SELF-recursive.
type R<T> = { [K in keyof T]?: T[K] extends object ? Merge<FE, R<T[K]>> : FE };
declare const r: R<{ sa: string[] }>;
export const rr: { sa?: { message?: string; type?: string } } = r;

// Same body, recursion through a twin alias — the reference answer.
type S<T> = { [K in keyof T]?: T[K] extends object ? Merge<FE, S2<T[K]>> : FE };
type S2<T> = { [K in keyof T]?: T[K] extends object ? Merge<FE, S2<T[K]>> : FE };
declare const s: S<{ sa: string[] }>;
export const ss: { sa?: { message?: string; type?: string } } = s;

// Which branch each key takes, spelled out.
type Probe<A, B> = {
  [K in keyof A | keyof B]?: K extends keyof A & keyof B
    ? "both"
    : K extends keyof A
      ? "onlyA"
      : "onlyB";
};
type P<T> = { [K in keyof T]?: T[K] extends object ? Probe<FE, P<T[K]>> : FE };
declare const p: P<{ sa: string[] }>;
export const pp: { sa?: { message?: "onlyA"; type?: "onlyA" } } = p;

// NEGATIVE: the members are real, so a wrong member type is still rejected.
export const neg: { sa?: { message?: number } } = r;
