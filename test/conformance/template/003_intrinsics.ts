// The four intrinsic string transforms.
type U = Uppercase<"hello">;
const u: U = "HELLO";
const u2: U = "hello"; // wrong -> TS2322

type L = Lowercase<"HeLLo">;
const l: L = "hello";

type C = Capitalize<"hello world">;
const c: C = "Hello world";

type Un = Uncapitalize<"Hello">;
const un: Un = "hello";

// Distribution over a union.
type UD = Uppercase<"a" | "b">;
const ud1: UD = "A";
const ud2: UD = "B";
const ud3: UD = "C"; // wrong -> TS2322

// Composed with a template.
type Shout<S extends string> = `${Uppercase<S>}!`;
const s: Shout<"hi"> = "HI!";
const s2: Shout<"hi"> = "hi!"; // wrong -> TS2322
