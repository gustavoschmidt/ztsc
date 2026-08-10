// tsc's `nonFixingMapper` leaves an un-inferred type parameter FREE in the
// contextual type it hands an argument, and every contextual READ then takes
// its apparent type (`getApparentTypeOfContextualType` maps `getApparentType`
// over it). So the object literal returned by the callback of
//
//     useAnimatedStyle<Style extends ViewStyle | ImageStyle | TextStyle>(
//         updater: () => Style)
//
// is contextually typed by the CONSTRAINT, which is what keeps
// `pointerEvents: cond ? 'box-none' : 'none'` a literal union instead of
// widening it to `string`, and what keeps `Style` inferred from the literal
// instead of collapsing to the constraint.
//
// ztsc substitutes an `any` placeholder for an un-inferred parameter, which
// erases it wherever it is NESTED — the callback's return type above all. The
// substitution is restricted to parameters that occur ONLY in the callback's
// return: an `any` in a contextual PARAMETER position is deliberate (tsc's
// free variable infers nothing from it either).

interface ViewStyle {
  opacity?: number | undefined;
  pointerEvents?: 'auto' | 'box-none' | 'box-only' | 'none' | undefined;
}
interface ImageStyle {
  opacity?: number | undefined;
  resizeMode?: 'cover' | 'contain' | undefined;
}
type DefaultStyle = ViewStyle | ImageStyle;
type PE = 'auto' | 'box-none' | 'box-only' | 'none' | undefined;
type Handle<S> = S & {viewDescriptors: number};

declare function useAnimatedStyle<Style extends DefaultStyle>(
  updater: () => Style,
): Handle<Style>;

declare const show: boolean;

const s = useAnimatedStyle(() => {
  return {
    pointerEvents: show ? 'box-none' : 'none',
    opacity: 1,
  };
});
// Clean: `pointerEvents` stayed the literal union.
const keptLiteral: PE = s.pointerEvents;
// And `Style` is the literal's own shape, not the constraint.
const notTheConstraint: number = s;

// A type parameter that also occurs in a PARAMETER position keeps the
// placeholder, so the constraint is not fed there and this call's `T` is still
// decided by the second argument alone.
declare function pair<T extends string | number>(cb: (x: T) => void, seed: T): T;
const p = pair(_x => {}, 'lit');
const stillTheSeed: number = p;
