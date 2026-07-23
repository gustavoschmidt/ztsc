// tsc widens a fresh-literal inference candidate (getWidenedLiteralType) before
// fixing a type parameter, UNLESS the param has a primitive/literal constraint
// or appears at the top level of the return type. Mirrors getCovariantInference.

declare function useState<S>(initial: S | (() => S)): [S, (a: S | ((p: S) => S)) => void];
declare function ident<T>(x: T): T;
declare function pair<S>(x: S): [S, S];
declare function pick<T extends "a" | "b">(x: T): T;

// WIDEN: S is a tuple element (not top-level in the return), no constraint —
// the literal argument widens to its base, so the setter accepts any base value.
const [, setRun] = useState(false);
setRun(true); // ok: S widened to boolean
const [, setS] = useState("a");
setS("hello"); // ok: S widened to string
const [, setN] = useState(1);
setN(5); // ok: S widened to number
const b = true;
const [, setB] = useState(b);
setB(false); // ok: candidate from `b` widens to boolean

// KEEP (top-level return): T is the whole return type, so the literal is kept.
const kept: false = ident(false); // ok
// KEEP (primitive/literal-union constraint): the constraint keeps the literal.
const p: "a" = pick("a"); // ok

// KEEP narrow — negative controls that must STILL error:
// as const produces a non-fresh literal, which is not widened.
const [, setC] = useState(true as const);
setC(false); // TS2345: false is not assignable to true
// an explicit type argument bypasses candidate widening entirely.
const [, setE] = useState<true>(true);
setE(false); // TS2345: false is not assignable to true

// WIDEN (covariant): a widened tuple element is observably `boolean`.
const first: false = pair(false)[0]; // TS2322: boolean is not assignable to false
