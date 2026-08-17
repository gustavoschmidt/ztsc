// tsc's `getContextualCallSignature` drops every candidate signature that is
// `isAritySmaller` than the function expression it would type, BEFORE it
// picks or combines what is left, and `getContextualSignature` does that per
// UNION constituent.

// A contextual signature narrower than the expression is no contextual
// signature at all: `a` is implicit `any` (TS7006), and the arrow is still
// checked against the annotation (TS2322).
const f: () => void = (a) => {};

// Per constituent: the zero-parameter one drops out and the one-parameter one
// still answers, so `e` is `string` and nothing is implicit.
type U = ((e: string) => void) | (() => void);
const g: U = (e) => {
  const s: string = e;
};

// The same through a type parameter's constraint — excalidraw's
// `withBatchedUpdates`. Filtering the COMBINED signature instead would have
// thrown the usable constituent away with the unusable one.
type TF = ((event: number) => void) | (() => void);
const w = <T extends TF>(func: T) =>
  ((event) => {
    const n: number = event;
  }) as T;

// An OVERLOAD SET filters the same way before combining: only `(x: number)`
// survives, so `q` is `number`.
declare function h(cb: { (): void; (x: number): void }): void;
h((q) => {
  const n: number = q;
});

// A rest parameter absorbs any arity and is never smaller.
declare function r(cb: (...xs: string[]) => void): void;
r((a, b) => {
  const s: string = a;
});

// A wide-enough signature is untouched.
declare function j(cb: (a: number, b: string) => void): void;
j((p) => {
  const n: number = p;
});
