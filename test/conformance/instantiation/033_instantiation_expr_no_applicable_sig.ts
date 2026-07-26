declare function plain(value: number): number;
declare function generic<T>(value: T): T;
declare const notCallable: { value: number };

// TS2635 when no signature accepts a type-argument list of this length.
const tooMany = plain<string>;
const wrongArity = generic<string, number>;
const notASignature = notCallable<string>;
