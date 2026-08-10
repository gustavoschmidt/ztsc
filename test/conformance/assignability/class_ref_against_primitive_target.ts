// tsc's `recursiveTypeRelatedTo` recurses into a source's structure only when
// BOTH sides are `StructuredOrInstantiable`. A PRIMITIVE target is not, so
// `isSimpleTypeRelatedTo` answers the pair and the source's members are never
// resolved.
//
// That gate is load-bearing when the question is asked from INSIDE the
// source's own declaration. react-native-gesture-handler's `BaseGesture<T>`
// declares a method whose parameter is `Exclude<GestureRef, number>`, and
// `GestureRef` is a union over `BaseGesture<...>` -- so materializing the
// class's member table asks whether each `BaseGesture<...>` extends `number`,
// re-entering the very table being built. A checker that expands the reference
// to answer gets its own in-progress marker back, which relates to everything,
// so `Exclude` drops every gesture constituent and every later call through
// the method is a phantom error.

declare abstract class Base {
  abstract toArray(): Kinds[];
}

declare abstract class Gest<P extends Record<string, unknown>> extends Base {
  tag: number;
  payload: P;
  with(...others: Exclude<Refs, number>[]): this;
}

type Kinds = Gest<Record<string, unknown>> | Gest<{ x: number }>;

interface Holder<T> {
  current: T;
}

type Refs = number | Kinds | Holder<Kinds | undefined>;

declare const n: Gest<{ x: number }>;
declare const holder: Holder<Kinds | undefined>;

// `Exclude<Refs, number>` keeps every non-number constituent, so a bare node
// and a holder both reach the parameter.
declare function want(...xs: Exclude<Refs, number>[]): void;
want(n);
want(holder);
n.with(n);
n.with(holder);

declare const ex: Exclude<Refs, number>;
const k: Kinds | Holder<Kinds | undefined> = ex;

// The primitive answers themselves are unchanged: no object type reaches one.
const bad1: number = n; // TS2322
const bad2: string = n; // TS2322
const bad3: number = holder; // TS2322
const bad4: boolean = n; // TS2322
const bad5: 5 = n; // TS2322
const bad6: null = n; // TS2322
