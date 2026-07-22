// A parameter with a default initializer (`b: boolean = false`) is optional
// in the function's call signature — its effective type for the contravariant
// relation admits `undefined` — so it is assignable to a target whose
// parameter is `?`-optional.
function f(a: string, b: boolean = false): void {}
const g: (a: string, b?: boolean) => void = f; // clean

// NEG CONTROL: a *required* parameter is NOT assignable to an optional-param
// target (the target could call with one argument, leaving `b` unset).
function h(a: string, b: boolean): void {}
const k: (a: string, b?: boolean) => void = h; // TS2322
