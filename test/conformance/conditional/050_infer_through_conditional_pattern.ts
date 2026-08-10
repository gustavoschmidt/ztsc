// A CONDITIONAL in the extends clause is an inference target: tsc's
// `inferFromTypes` offers the source to BOTH branches
// (`inferToMultipleTypes([trueType, falseType])`) and demotes what they bind —
// `ContravariantConditional` in a contravariant position, `NakedTypeVariable`
// for a branch that IS the binder. Without an arm for it a binder reachable
// only through a conditional was never inferred at all, which is how
// react-native-reanimated's
//     type ExtractElementRef<TRef> =
//       TRef extends ElementType ? ComponentRef<TRef> : TRef
// left every `useAnimatedRef<Animated.X>().current` with no members.
//
// The binder is DECLARED in an ordinary generic position (that is what makes
// the enclosing conditional own it) and only USED inside the conditional.

type Wrap<X> = X extends string ? "str" : X;

// 1. Used only through a conditional, in a covariant position.
interface Holder<X> { v: Wrap<X> }
type FromHolder<T> = T extends Holder<infer M> ? M : never;
declare const h1: FromHolder<Holder<{a: number}>>;
const h1a: number = h1.a;
const h1bad: string = h1.a; // TS2322

// 2. The same, reached CONTRAVARIANTLY through a callback parameter — the
//    `InferencePriority.ContravariantConditional` position.
interface Sink<X> { cb: (arg: Wrap<X> | null) => void }
type FromSink<T> = T extends Sink<infer M> ? M : never;
interface Inst { m(): number }
declare const s1: FromSink<Sink<Inst>>;
const s1m: number = s1.m();

// 3. A DIRECT structural candidate and a conditional one for the SAME binder:
//    the ladder keeps only the best priority a binder ever saw, so the direct
//    match answers alone and the conditional branch cannot widen it.
interface Both<X> { direct: X; via: Wrap<X> }
type FromBoth<T> = T extends Both<infer M> ? M : never;
declare const b1: FromBoth<Both<{k: 1}>>;
const b1k: 1 = b1.k;

// 4. Union target with a naked binder beside a wrapper constituent: the
//    wrapper names the binder structurally and outranks the bare arm
//    (`InferencePriority.NakedTypeVariable`).
interface Box<X> { boxed: X }
type FromUnion<T> = T extends {p: Box<infer M> | infer M} ? M : never;
declare const f1: FromUnion<{p: Box<{q: string}>}>;
const f1q: string = f1.q;
