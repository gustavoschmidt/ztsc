// `as const` does not widen a primitive literal: the type stays the literal,
// so assigning it to the exact literal type is fine and reassigning through a
// wider annotation keeps the narrow type.
const s = "a" as const;
const n = 5 as const;
const b = true as const;
const s2: "a" = s;
const n2: 5 = n;
const b2: true = b;
