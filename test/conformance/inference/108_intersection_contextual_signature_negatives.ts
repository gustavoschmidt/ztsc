// Negatives for 107: the combined signature's parameter is the UNION of the
// constituents' parameters, so a use valid for only one of them is rejected,
// and an intersection that carries no usable call signature still leaves the
// arrow context-free (implicit any under noImplicitAny).

type A = { onToggle?: (open: boolean) => void };
type B = { onToggle?: (ev: { t: string }) => void };

declare function take(p: A & B): void;

// `open` is `boolean | { t: string }`; `.t` is not on the boolean arm.
take({ onToggle: (open) => { open.t; } });
// ...and it is not a `boolean` either.
take({
  onToggle: (open) => {
    const b: boolean = open;
    return b;
  },
});

// An intersection with NO call signature gives no contextual signature, so the
// arrow's parameter is an implicit any.
type C = { a?: number };
type D = { b?: string };
declare function take2(p: (C & D) | ((x: number) => void)): void;
declare function take3(p: C & D): void;
take3({ a: 1, b: "s" });
declare const cb: C & D;
export const e: typeof cb = { a: 1 };
