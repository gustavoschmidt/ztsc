declare function wrap<T>(value: T): T[];

// Negative: type arguments followed by `(` are still a generic *call*, not an
// instantiation expression that happens to be called.
const list: number[] = wrap<number>(1);
wrap<number>("no");

// The same callee with no argument list is the instantiation expression.
const wrapNumber = wrap<number>;
const also: number[] = wrapNumber(2);
