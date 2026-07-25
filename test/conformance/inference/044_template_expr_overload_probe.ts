// Overload probing must contextually type a template-literal EXPRESSION
// argument by the CANDIDATE's parameter. Probing context-free widens the
// argument to `string`, which fails the generic overload's `N extends P<T>`
// constraint, so every candidate is rejected and the call reports TS2769 —
// the react-hook-form `watch(`contacts.${i}.type`)` regression vector.
//
// Companion to case 043 (single non-overloaded signature); here the correct
// signature is only reachable if the probe itself is contextual.
//
// The `const z: 0 = r` reveal pins the inferred type via the TS2322 message.

declare const i: number;

type P<T> = T extends object ? "a" | `b.${number}` : never;

interface I<T> {
  m(): T;
  m(xs: readonly P<T>[]): string;
  m<N extends P<T>>(x: N): N;
}

declare const o: I<{ x: 1 }>;

// The template expression matches the `b.${number}` constituent of P<{x:1}>,
// so overload 3 is selected and N infers to the template-literal type. The ONLY
// diagnostic is the reveal below — in particular NO TS2769 on this call.
const r1 = o.m(`b.${i}`);
const z1: 0 = r1; // TS2322 — Type '`b.${number}`' is not assignable to type '0'.
