// tsc's `isEmptyObjectType` is `some(constituents, isEmptyObjectType)` over a
// union, and `hasExcessProperties` bails on it wholesale — so a union with an
// empty-object constituent accepts any property, exactly like a bare `{}`
// target. `T | {}` is the `?? {}` / optional-bag shape.

interface Alg {
  name: string;
}

declare function withEmptyLiteral(a: Alg | {}): void;
withEmptyLiteral({ nope: 1 });

declare function withObjectKeyword(a: Alg | object): void;
withObjectKeyword({ nope: 1 });

interface Emptyish {}
declare function withEmptyInterface(a: Alg | Emptyish): void;
withEmptyInterface({ nope: 1 });

// Bare `{}` control (already correct).
declare function bareEmpty(a: {}): void;
bareEmpty({ nope: 1 });

// NOT empty: a string index signature is a "knows the property" route, so the
// union takes the literal — for a different reason than the empty bail.
declare function withStringIndex(a: Alg | Record<string, number>): void;
withStringIndex({ nope: 1 });

// NOT empty: every constituent has properties, so an unknown one is excess.
interface Gcm extends Alg {
  iv: number;
}
declare function noEmpty(a: Alg | Gcm): void;
noEmpty({ name: "x", nope: 1 });
