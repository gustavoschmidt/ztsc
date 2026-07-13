// An object literal `as const` makes every property readonly and literal-typed.
const obj = { a: 1, b: "x" } as const;
const a1: 1 = obj.a;
const b1: "x" = obj.b;
obj.a = 2;
obj.b = "y";
