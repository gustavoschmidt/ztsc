// tsc's `inferFromMatchingTypes` runs twice over a union's constituents:
// `isTypeOrBaseIdenticalTo` first, then `isTypeCloselyMatchedBy` — "s and t are
// two instantiations of the same generic". A matched pair is inferred on its
// own and BOTH sides are removed, so a multi-constituent union target never
// receives the whole source union (which is neither a function nor a
// `RefObject`, and so infers nothing).
//
// This is React 19's `ComponentRef` shape, the one every
// `useAnimatedRef<Animated.X>().current` resolves through.

type RefCallback<T> = (instance: T | null) => void;
interface RefObject<T> { current: T }
type Ref<T> = RefCallback<T> | RefObject<T | null> | null;
interface RefAttributes<T> { ref?: Ref<T> | undefined }

interface ScrollViewInst { getScrollResponder(): number }
interface SVProps { horizontal?: boolean }

type ComponentRefOf<T> = T extends RefAttributes<infer Method> ? Method : never;

// Two wrapper constituents, no naked binder: `RefCallback<ScrollViewInst>`
// pairs with `RefCallback<Method>` and `RefObject<ScrollViewInst | null>` with
// `RefObject<Method | null>`.
declare const r1: ComponentRefOf<RefAttributes<ScrollViewInst>>;
r1.getScrollResponder();
const r1bad: string = r1.getScrollResponder(); // TS2322

// The source is an INTERSECTION carrying the same `ref` property.
declare const r2: ComponentRefOf<SVProps & RefAttributes<ScrollViewInst>>;
r2.getScrollResponder();

// Only ONE of the two wrappers present on the source still pairs.
interface OnlyObject<T> { ref?: RefObject<T | null> | RefCallback<T> }
type FromObject<T> = T extends OnlyObject<infer M> ? M : never;
declare const r3: FromObject<{ref?: RefObject<ScrollViewInst | null>}>;
r3.getScrollResponder();

// An unrelated constituent contributes nothing: `Method` comes only from the
// pair that shares a generic, never from `Other` by cross-matching.
interface Other { tag: "other" }
interface Mixed<T> { ref?: RefCallback<T> | Other }
type FromMixed<T> = T extends Mixed<infer M> ? M : never;
declare const r4: FromMixed<{ref?: RefCallback<ScrollViewInst> | Other}>;
r4.getScrollResponder();
