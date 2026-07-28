// Inferring an OBJECT parameter from a UNION argument — the shape a generic
// call takes when its contextual return type is a union. Pair by the generic
// ORIGIN when the constituents are aliases, otherwise by the parameter's own
// DISCRIMINANT.
type A<P extends string> = { t: "a"; d: P };
type B<P extends string> = { t: "b"; d: P[] };
declare function mkA<P extends string>(n: number): A<P>;

// origin pairing: the `A` constituent is the one that infers
export const o1 = <P extends string>(n: number): A<P> | B<P> => mkA(n);
// …including with a non-object constituent alongside
export const o2 = <P extends string>(n: number): A<P> | null => mkA(n);
// non-union control
export const o3 = <P extends string>(n: number): A<P> => mkA(n);

// discriminant pairing: the contextual union's constituents are anonymous
// object literals, so only `t: "poly"` identifies the right one
type Shape<P extends string> = { t: "poly"; d: P[] } | { t: "seg"; d: [P, P] };
declare function mkPoly<P extends string>(n: number): { t: "poly"; d: P[] };
export const s1 = <P extends string>(n: number): Shape<P> => mkPoly(n);

// the inference really happened: a wrong element type is still rejected
declare function mkPolyNum(n: number): { t: "poly"; d: number[] };
export const s2 = <P extends string>(n: number): Shape<P> => mkPolyNum(n); // TS2322

// NO discriminant: sibling object literals must contribute nothing, or the
// merged candidate widens past the union the call was given
type Choice<T> = { value: T; label: string };
declare function pick<T>(value: T, choices: Choice<T>[]): (v: T) => void;
const onChange: (v: "x" | "y") => void = pick("x" as "x" | "y", [
  { value: "x", label: "X" },
  { value: "y", label: "Y" },
]);
void onChange;

// an interface constituent keeps taking the ref path
interface IA<P extends string> {
  t: "a";
  d: P;
}
interface IB<P extends string> {
  t: "b";
  d: P[];
}
declare function mkIA<P extends string>(n: number): IA<P>;
export const i1 = <P extends string>(n: number): IA<P> | IB<P> => mkIA(n);
