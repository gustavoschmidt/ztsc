// Contextual typing of an object-literal property must reach a property that
// lives in a UNION member of an INTERSECTION contextual type (and through a
// union — an optional parameter `T | undefined` — wrapping that intersection).
// This is react-hook-form's `register(name, opts?: RegisterOptions)` where
// `RegisterOptions = Partial<Common> & (A | B | C)` and the discriminant
// `valueAsNumber?: false | true` lives only in the union arms. Without the
// contextual type, a fresh `valueAsNumber: true` widened to `boolean` and
// matched no arm (TS2345 false positive).

type ValidationRule<T> = T | { value: T; message: string };
type RegisterOptions = Partial<{
  required: string | { value: boolean; message: string };
  min: ValidationRule<number>;
  disabled: boolean;
}> & (
  | { pattern?: ValidationRule<RegExp>; valueAsNumber?: false; valueAsDate?: false }
  | { pattern?: undefined; valueAsNumber?: false; valueAsDate?: true }
  | { pattern?: undefined; valueAsNumber?: true; valueAsDate?: false }
);

declare function register(name: string, opts?: RegisterOptions): void;

// POSITIVE: `valueAsNumber: true` keeps its literal via the contextual arm and
// matches the third union member — assignable, no error. On the pre-fix tree
// each of these widened `valueAsNumber` to `boolean` and reported TS2345, so a
// clean run here locks the fix.
register("a", { valueAsNumber: true });
register("b", { valueAsNumber: true, required: "msg" });
register("c", { min: { message: "m", value: 1 }, required: "r", valueAsNumber: true });

// Negative controls are exercised out-of-tree (both ztsc and tsgo reject a
// `valueAsNumber:true`+`valueAsDate:true` combination and a wrong-typed common
// prop). They are omitted here because ztsc reports the whole-argument code
// (TS2345) while tsc drills into the offending property (TS2322) — a
// pre-existing reporting divergence unrelated to the contextual-typing fix.
