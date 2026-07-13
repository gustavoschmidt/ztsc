// The result of `satisfies` is the operand's narrow type, not the target, so
// a string literal validated against a union stays that literal.
type Dir = "n" | "s";
const d = "n" satisfies Dir;
const same: "n" = d;
