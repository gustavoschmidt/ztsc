// `infer` against a UNION pattern follows tsc's `inferFromTypes` union rule:
// "first infer between identically matching source and target constituents
// and remove the matched types from consideration", and only the RESIDUAL
// source reaches the infer-bearing constituents. Without the subtraction the
// infer variable swallows the constituents the pattern already spells out.
//
// kysely's `AliasedExpression<T, A>` is the shape that matters:
// `get alias(): A | Expression<unknown>`. Reading the column alias out with
// `X extends AliasedExpression<any, infer EA> ? EA : never` infers `EA` from
// `"foo" | Expression<unknown>` against `EA | Expression<unknown>`, and
// without the subtraction `EA` came back as the whole union — not a property
// name, so the mapped `Selection` that keys a row type off it dropped the
// column and every later read of it was a TS2339.

interface Marker {
  readonly kind: 'marker';
}

interface Aliased<O, A extends string> {
  readonly expression: O;
  readonly alias: A | Marker;
}

type AliasOf<E> = E extends Aliased<any, infer A> ? A : 'NONE';

// (1) through a reference — identity pairing on the type arguments
type ViaRef = AliasOf<Aliased<number, 'count'>>;
const a1: 'count' = null as unknown as ViaRef;

// (2) through the STRUCTURAL form, which is where the union rule fires
type ViaStructure = AliasOf<{ readonly expression: number; readonly alias: 'count' | Marker }>;
const a2: 'count' = null as unknown as ViaStructure;

// (3) the same rule with the matched constituent on the OTHER side of the
// union, and with two of them
type Pair<A> = A | Marker | null;
type Un<E> = E extends Pair<infer A> ? A : 'NONE';
const a3: 'x' = null as unknown as Un<'x' | Marker | null>;

// (4) nothing matches: the whole source still reaches the variable
const a4: 'x' | Marker = null as unknown as Un<'x' | Marker>;

// (5) everything matches: tsc still offers the whole source
const a5: Marker | null = null as unknown as Un<Marker | null>;

// (6) the residual is what the key remap of a mapped type reads
type Selection<SE> = { [E in SE as AliasOf<E>]: 1 };
declare const sel: Selection<Aliased<number, 'count'>>;
const a6: 1 = sel.count;

export { a1, a2, a3, a4, a5, a6 };
