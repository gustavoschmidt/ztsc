// An INHERITED constructor signature carries the type ARGUMENTS the heritage
// clause wrote. `class Comp extends Base<Props> {}` declares no constructor,
// so it inherits `Base<P>`'s `constructor(props: P)` — and that signature has
// to read `constructor(props: Props)`. Walking to the base SYMBOL alone drops
// the reference's arguments and lets the base's own parameter escape into
// `typeof Comp`, where nothing can bind it.
//
// It shows through any pattern that reads a class's construct signature.
// `React.ComponentProps<typeof C>` is `typeof C extends
// JSXElementConstructor<infer P> ? P : never`, so the free parameter is what
// `infer P` matched: every React Native host component's props type came back
// as an unbound type parameter (`<View>`'s among them), which is
// `classes/079_mixin_base_intersection`'s shape one level further on — the
// base there is `Constructor<NativeMethods> & typeof ViewComponent`, and
// `ViewComponent` is `class ViewComponent extends React.Component<ViewProps>`.

interface Props {
  a: string;
}
interface Api {
  focus(): void;
}
type Ctor<T> = new (...args: any[]) => T;

declare class Base<P> {
  constructor(props: P);
  props: P;
}
declare class Comp extends Base<Props> {}

// The pattern `ComponentProps` is built on.
type CtorArg<T> = T extends new (p: infer P, ...r: any[]) => any ? P : "none";

type Direct = CtorArg<typeof Comp>;
const d1: Direct = {a: "x"};
const d2: Direct = {a: 1}; // TS2322

// Through a mixin intersection, as react-native writes it.
declare const Mixed: Ctor<Api> & typeof Comp;
class Widget extends Mixed {}

type Through = CtorArg<typeof Widget>;
const w1: Through = {a: "x"};
const w2: Through = {a: 1}; // TS2322

// The instance still has both sides.
declare const w: Widget;
w.focus();
const p1: string = w.props.a;
const p2: number = w.props.a; // TS2322

// Composition down a chain: an argument written on one clause may mention the
// parameters of the class writing it.
declare class Mid<T> extends Base<T[]> {}
declare class Leaf extends Mid<number> {}
type LeafArg = CtorArg<typeof Leaf>;
const l1: LeafArg = [1, 2];
const l2: LeafArg = ["x"]; // TS2322

// A class with its OWN constructor is unaffected — no substitution applies.
declare class Own<T> extends Base<T> {
  constructor(x: T, y: number);
}
type OwnArg = CtorArg<typeof Own>;
const o1: OwnArg = "anything";
