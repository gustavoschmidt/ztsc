declare function identity<T>(value: T): T;

// TS 4.7 instantiation expression: the type arguments specialize the
// signature without calling it.
const numberIdentity = identity<number>;
const n: number = numberIdentity(1);
const bad: string = numberIdentity(1);
numberIdentity("no");
