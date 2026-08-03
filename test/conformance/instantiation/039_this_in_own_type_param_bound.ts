// A method whose OWN type parameter is bounded by a type mentioning the
// polymorphic `this` — zod v4's
// `refine<Ch extends (arg: output<this>) => unknown>(check: Ch): this`.
//
// A signature's type parameters are held by SYMBOL, and a symbol's bound is
// read back off the AST, so substituting the receiver for `this` through the
// signature's parameter and return types alone never reaches the bound. The
// argument's contextual type comes from exactly that bound, so the callback
// was contextually typed by an unreduced `this extends … ? this[…] : unknown`:
// every parameter fell to an implicit `any` (TS7006) and every use of one was
// TS2339 on the deferred conditional.
//
// tsc has no such gap by construction — it appends the interface's `thisType`
// to its type parameters and the receiver to its type arguments, so ordinary
// instantiation (which does clone own parameters with substituted bounds)
// covers `this` as well. `substThis` mirrors that here.

type Out<T> = T extends { _zod: { output: any } } ? T['_zod']['output'] : unknown;

declare class Schema<O> {
  _zod: { output: O };
  // Bound reaches `this` through an alias …
  refine<Ch extends (arg: Out<this>) => unknown>(check: Ch): this;
  // … and directly, through an indexed access.
  check<Ch extends (arg: this['_zod']['output']) => unknown>(check: Ch): this;
  // A SIBLING own parameter naming the one before it has to see the rewritten
  // symbol, not the original (the reason the rewrites accumulate in order).
  pair<A extends Out<this>, B extends A[]>(a: A, b: B): this;
  // A defaulted bound moves the same way.
  fold<A extends Out<this> = Out<this>>(a: A): A;
}

declare const s: Schema<string[]>;

s.refine((arr) => arr.every((x) => x.length > 0));
s.check((arr) => arr.map((x) => x.trim()).length);
s.pair(['a'], [['a']]);
const folded: string[] = s.fold(['a']);

// A subclass receiver resolves `this` to itself, not to the declaring class.
declare class NumSchema extends Schema<number[]> {
  extra: boolean;
}
declare const n: NumSchema;
n.refine((arr) => arr.every((x) => x.toFixed(2) !== ''));
const back: NumSchema = n.check((arr) => arr.length);

export { folded, back };
