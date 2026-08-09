// A generic alias' expansion is interned structurally, so `Rec<string,
// unknown>`'s member table IS the object `{ [s: string]: unknown }` that
// `pick`'s first overload parameter instantiates to. Whether that object
// carries an `origin` tag naming `Rec` is a fact about what the checker has
// already expanded — here, whether `./seed` was reached first — so no relation
// rule may DECIDE on it. It used to: the variance probe matched `Rec` on both
// sides and answered "related", picking the generic overload with `V`
// uninferred, and `use.ts`'s `v` came out `unknown`.
import './seed'
import './use'
