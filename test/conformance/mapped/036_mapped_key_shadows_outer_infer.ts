// A mapped type's key parameter `[P in ...]` is declared lexically INSIDE the
// conditional branch that binds a same-named `infer P`, so within the mapped
// `as`/value branches a bare `P` is the mapped param and shadows the outer
// infer binder (innermost-wins, matching tsc). Before the fix the infer scope
// was consulted first, so the value bound `T[infer P]`; the (route-dependently
// unbound) infer var collapsed the indexed access to `any`, dropping the real
// member types — and, for non-homomorphic Pick/Omit, every modifier — which
// produced the `--checkers`-partition-dependent TS2739/TS2322 non-confluence on
// the dogfood project's component-props types. Distilled from that defect.
interface Src {
  req: string;
  opt?: number;
}

// identity map nested in a conditional `infer P` branch; key named P
type Identity<T> = T extends infer P ? { [P in keyof T]: T[P] } : never;
type W = Identity<Src>;

// modifiers preserved: `opt` stays optional, `req` stays required.
const ok: W = { req: "x" }; // ok — opt is optional
const miss: W = { opt: 3 }; // TS2741: req missing (negative control — required stays required)

// value types preserved (NOT collapsed to `any`): W["req"] is `string`.
const good: string = ({} as W).req; // ok
const bad: number = ({} as W).req; // TS2322: string is not assignable to number
