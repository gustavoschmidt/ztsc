// A homomorphic mapped / indexed-access / conditional over `typeof <module>`
// whose value members are *generic* functions. The signature's own `<T>` is
// not a free type variable of the namespace, so the object is concrete and
// the members must survive the map — regression guard for the
// @testing-library `screen` bucket (BoundFunctions<typeof queries>), where
// `screen.getByText` was lost as a spurious TS2339.
import * as queries from './q'

type BoundFunction<T> = T extends (
  container: object,
  ...args: infer P
) => infer R
  ? (...args: P) => R
  : never

type BoundFunctions<Q> = Q extends typeof queries
  ? {[P in keyof Q]: BoundFunction<Q[P]>}
  : {[P in keyof Q]: BoundFunction<Q[P]>}

type Screen = BoundFunctions<typeof queries> & {
  debug(): void
}

declare const screen: Screen

screen.getByText('id')
screen.findByRole('button')
screen.debug()
