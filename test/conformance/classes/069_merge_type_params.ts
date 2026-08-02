// The two halves of a class+interface merge each bind their own type
// parameters; they unify by POSITION. Arity, constraints and defaults stay
// with the first declaring block (@types/react writes `interface
// Component<P = {}, S = {}, SS = any>` beside `class Component<P, S>`), but
// the class's own `implements`/`extends` clauses must still line up with the
// instance type.
interface P<A> {
  x: A;
}
declare class P<A> {
  y: A;
}
declare const p: P<number>;
const p1: number = p.x;
const p2: number = p.y;
const p3: string = p.x;
const p4: string = p.y;

// The interface half declares MORE (defaulted) parameters than the class.
interface Q<A = {}, B = {}, C = string> {
  x: A;
  c: C;
}
declare class Q<A, B> {
  y: B;
}
declare const q: Q<number>;
const q1: number = q.x;
const q2: string = q.c;
const q3: string = q.y;

// An `implements` clause written on the class body, with the interface half
// first, must compare against the same parameter.
interface R<T> {
  readonly slot: {
    readonly v: T;
  };
}
interface S<T> extends R<T> {
}
declare class S<T> implements R<T> {
  readonly slot: {
    readonly v: T;
  };
}
