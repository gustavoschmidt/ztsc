// The TS2367/TS2678 overlap test resolves a type parameter to its constraint
// — and an UNCONSTRAINED one overlaps everything, because it could be
// instantiated to the other operand's type. ztsc applied that only at the top
// level of each operand, so a parameter buried one layer inside an
// instantiation had no such leniency and `switch (key)` on a
// `ClassConstructor<T>` rejected a `case` of type
// `ClassConstructor<LoggingRepository>` (immich `test/medium.factory.ts:493`).
//
// tsc's `relateVariances` pairs the type arguments of two references to ONE
// generic instead of walking their members, which is what puts the parameter
// back in an operand position.

interface Ctor<T> {
  new (...args: any[]): T;
}
interface Box<T> {
  v: T;
}

class A {
  a = 1;
}

declare const aCtor: Ctor<A>;
export function f1<T>(key: Ctor<T>): void {
  switch (key) {
    case aCtor:
      break;
  }
}

declare const aBox: Box<A>;
export function f2<T>(key: Box<T>): void {
  switch (key) {
    case aBox:
      break;
  }
}

// The equality form of the same question.
export function f3<T>(key: Box<T>): boolean {
  return key === aBox;
}

// A constrained parameter whose constraint DOES overlap.
export function f4<T extends A>(key: Box<T>): boolean {
  return key === aBox;
}

// A type alias that materializes into an object still pairs by origin.
type Pair<T> = { first: T; second: T };
declare const aPair: Pair<A>;
export function f5<T>(key: Pair<T>): boolean {
  return key === aPair;
}

export {};
