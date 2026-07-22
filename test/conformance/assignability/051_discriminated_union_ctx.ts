// Discriminant-guided contextual typing (tsc's
// `discriminateTypeByDiscriminantProperties`): an object literal typed by a
// discriminated union keeps a property's literal type by first selecting the
// constituent whose discriminant matches the literal-valued source property,
// instead of widening the property against the union-wide member type. Here
// `stepCode` is the literal `"X"` in the `"a"`/`"b"` arms but `string` in the
// `"debit"` arm, so the union-wide `stepCode` type is `"X" | string` = `string`;
// widening a fresh `stepCode: "X"` to `string` would then match no arm's literal
// discriminant. Selecting the `kind: "a"` arm first keeps `stepCode: "X"`.

type Action =
  | { kind: "a"; stepCode: "X"; reason: string }
  | { kind: "b"; stepCode: "X"; ownerKind: "O"; reason: string }
  | { kind: "debit"; stepCode: string; debit: { amount: number }; reason: string };

// POSITIVE: discriminant `kind: "a"` selects the first arm, so `stepCode: "X"`
// keeps its literal and the element is assignable — no error.
const ok: Action[] = [{ kind: "a", stepCode: "X", reason: "r" }];

// POSITIVE: same, nested through a `Partial<{ actions: Action[] }>` literal.
type Ctx = { actions: Action[]; other: number };
const ok2: Partial<Ctx> = { actions: [{ kind: "a", stepCode: "X", reason: "r" }] };

// NEGATIVE: discriminant `kind: "zzz"` matches no arm, so the full union stands
// and the mismatch is reported.
const bad: Action[] = [{ kind: "zzz", stepCode: "X", reason: "r" }];

// NEGATIVE: discriminant selects the `debit` arm but the required `debit`
// property is missing, so the selected arm still rejects it.
const bad2: Action[] = [{ kind: "debit", stepCode: "Y", reason: "r" }];

export { ok, ok2, bad, bad2 };
