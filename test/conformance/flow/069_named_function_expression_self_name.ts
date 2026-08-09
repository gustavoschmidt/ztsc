// A NAMED function expression can name itself inside its own body — tsc's
// `resolveName` stops at the FunctionExpression whose name matches — and
// nowhere else. Bluesky's tween loop is written this way.
const fact = function recur(n: number): number {
    return n <= 1 ? 1 : n * recur(n - 1);
};
const v: number = fact(5);

// The name is NOT visible outside the expression.
const outside = recur;

// A parameter of the same name shadows the self-reference.
const shadowed = function me(me: string): string {
    return me;
};
const s: string = shadowed("x");

// The self-reference carries the function's own signature, so a bad call is
// still an error.
const strict = function again(n: number): number {
    return again("no");
};

export { v, outside, s, strict };
