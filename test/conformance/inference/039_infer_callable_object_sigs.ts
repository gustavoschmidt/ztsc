// ComponentProps<typeof X> collapse for exotic (callable-object) components.
// A conditional `T extends JSXElementConstructor<infer P> ? P : {}` must infer
// P from a callable object's CALL signature (ForwardRefExoticComponent) and
// from a construct signature (the class constituent) — not fall to `{}`.
type ReactNode = string | number | null;
declare class Component<P, S> {
  props: P;
  state: S;
}
type JSXElementConstructor<P> =
  | ((props: P) => ReactNode | Promise<ReactNode>)
  | (new (props: P) => Component<any, any>);
type ComponentProps<T> = T extends JSXElementConstructor<infer P> ? P : {};

// Callable object (call signature only) — ForwardRefExoticComponent shape.
interface ForwardRefExoticComponent<P> {
  (props: P): ReactNode;
  displayName?: string;
}
declare const Fwd: ForwardRefExoticComponent<{ a: number; b: string }>;
type P1 = ComponentProps<typeof Fwd>;
declare const p1: P1;
const a1: number = p1.a;
const b1: string = p1.b;

// Bare function pattern against the callable object.
type FromFn<T> = T extends (props: infer P) => any ? P : {};
type P2 = FromFn<typeof Fwd>;
declare const p2: P2;
const a2: number = p2.a;

// Overloaded callable: tsc aligns signatures from the end, so the LAST call
// signature supplies P.
interface Overloaded {
  (props: { a: number }): ReactNode;
  (props: { z: boolean }): ReactNode;
}
declare const Ov: Overloaded;
type P3 = FromFn<typeof Ov>;
declare const p3: P3;
const z3: boolean = p3.z;

// Construct-signature object vs construct pattern.
type FromCtor<T> = T extends new (props: infer P) => any ? P : {};
interface CtorObj {
  new (props: { k: number }): Component<any, any>;
}
declare const Ct: CtorObj;
type P4 = FromCtor<typeof Ct>;
declare const p4: P4;
const k4: number = p4.k;

// Negative control: a plain object with NO call/construct signature must stay
// on the false branch → {}. Accessing a property is an error on `{}`.
interface Plain {
  a: number;
}
declare const Pl: Plain;
type P6 = ComponentProps<typeof Pl>;
declare const p6: P6;
const bad6 = p6.a;
