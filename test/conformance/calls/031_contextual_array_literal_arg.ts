// Array-literal arguments are contextually typed by the parameter type,
// looking through unions: each array-like union constituent contributes its
// element type, so literal elements stay literal instead of widening. This is
// the react-hook-form `trigger(['a','b'])` shape where the parameter is
// `Path<F> | Path<F>[]` (a literal union and its array).

// Union of a literal-union and its array (the RHF trigger shape).
declare function f1(x: "a" | "b" | ("a" | "b")[]): void;
f1(["a", "b"]); // ok: element ctx "a"|"b" keeps literals
f1("a"); // ok
f1(["a", "c"]); // error: "c" not in "a"|"b"

// Pure array parameter with a literal-union element.
declare function f2(x: ("a" | "b")[]): void;
f2(["a", "b"]); // ok

// Nested arrays under a union context.
declare function f3(x: "a" | "b" | ("a" | "b")[][]): void;
f3([["a", "b"], ["a"]]); // ok

// Union whose constituent is a tuple -> tuple context.
declare function f4(x: number | ["a", "b"]): void;
f4(["a", "b"]); // ok

// Negative control: no literal context, plain string[] should still widen.
declare function f5(x: string[]): void;
const arr = ["a", "b"];
f5(arr); // ok

// Negative control: element absent from every union constituent.
declare function f6(x: "a" | "b" | ("a" | "b")[]): void;
f6(["a", "x"]); // error: "x" not in "a"|"b"
