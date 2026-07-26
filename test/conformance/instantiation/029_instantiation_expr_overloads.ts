declare function pick(a: number): number;
declare function pick<T>(a: T, b: T): T;
declare function pick<A, B>(a: A, b: B): [A, B];

// One type argument: only the middle overload can take it — the non-generic
// first and the two-parameter third are dropped.
const one = pick<string>;
const same: string = one("a", "b");
one("a", 2);

// Two type arguments select the third overload instead.
const two = pick<string, number>;
const pair: [string, number] = two("a", 1);
two("a", "b");
