// A `Pick`/`Omit` whose modifiers type is an *intersection of objects*
// (`Omit<Partial<Base> & (A | B), K>` — react-hook-form `RegisterOptions`)
// must preserve the optional modifier that the `Partial<…>` constituent adds.
// Before the fix the intersection modifiers-type was ignored (only a bare
// `.object` was honored), so every non-homomorphic mapped prop read as required
// and a partial object literal spuriously failed (TS2739/TS2741).
interface Base {
  required: string;
  min: number;
  deps: string;
  value: number;
}
type U = { pattern?: 0; a?: false } | { pattern?: 1; a?: true };

// `value` omitted; every remaining prop is optional via `Partial`.
type RO = Omit<Partial<Base> & U, "value">;
const a: RO = { required: "x" };

type Pk = Pick<Partial<Base> & U, "required" | "min">;
const b: Pk = { required: "x" };

// Negative control: a genuinely-required Pick prop that is missing still errors.
interface Req {
  x: string;
  y: number;
}
type PkReq = Pick<Req, "x" | "y">;
const c: PkReq = { x: "v" };
