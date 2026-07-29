// A `default:` clause is only `never` when the `case` labels cover EVERY
// discriminant value. Partial coverage keeps the surviving constituents
// whole — a constituent with a wide discriminant is never split apart.
declare function assertNever(x: never, msg: string): never;

type U = { type: "a" | "b"; ab: number } | { type: "c"; c: number };

// "b" is not covered, so the whole `{ type: "a" | "b" }` constituent reaches
// `default:` — unsplit, exactly as tsc leaves it.
export const f = (u: U): number => {
  switch (u.type) {
    case "a":
      return u.ab;
    case "c":
      return u.c;
    default:
      return assertNever(u, "boom");
  }
};

// The same partial coverage inside a `case`: `case "a"` keeps the constituent
// whole, it does not narrow `type` down to `"a"`.
export const g = (u: U): "a" => {
  switch (u.type) {
    case "a":
      return u.type;
    default:
      return "a";
  }
};

// A non-unit case label decides nothing.
declare const wide: string;
export const h = (u: U): number => {
  switch (u.type) {
    case "a":
    case "b":
      return u.ab;
    case wide:
      return 0;
    default:
      return assertNever(u, "boom");
  }
};

// A naked type parameter whose constraint the cases do NOT cover.
export const i = <T extends "a" | "b" | "c">(t: T): number => {
  switch (t) {
    case "a":
      return 1;
    case "b":
      return 2;
    default:
      return assertNever(t, "boom");
  }
};
