// An inference that VIOLATES its type parameter's constraint is replaced by the
// constraint — and the replacement has to reach the contextual type a callback
// argument is checked under, not just the final answer.
//
// tsc reaches every inference variable in a contextual type through
// `getInferredType`, whose last act is "if the inferred type does not satisfy
// the constraint, use the constraint instead". So the callback's parameter is
// the CONSTRAINT, and its body is checked against that. ztsc clamped only at
// the end, after the callback body had already been walked (and its per-node
// types published) under the violating inference — so outline's
// `everyActiveModel(context, Document, (d) => d.isStarred)` typed `d` as
// `Document` and lost the whole `Property 'x' does not exist on type 'Model'`
// family.
//
// `Sub` does not satisfy `Base` here for the reason outline's models do not:
// the property `self` is a `Holder<T>` whose `add` is a function-typed PROPERTY,
// so its parameter is contravariant and `Holder<Sub>` is not a `Holder<Base>`.

class Base {
  id = "";
  self!: Holder<Base>;
}
class Holder<T extends Base> {
  add = (item: T): T => item;
}
class Sub extends Base {
  declare self: Holder<Sub>;
  extra = "";
}

declare function every<T extends Base>(
  cls: new (...args: never[]) => T,
  predicate: (model: T) => boolean
): boolean;

// T infers `Sub`, clamps to `Base`: the class argument fails AND `extra` is not
// a property of what the callback's parameter now is.
export const a = every(Sub, (m) => !!m.extra);

// An ANNOTATED callback parameter is its own type, so only the class argument
// is reported.
export const b = every(Sub, (m: Sub) => !!m.extra);

// A satisfying argument is untouched — the clamp must not fire on `Base`.
export const c = every(Base, (m) => !!m.id);

// A callback whose parameter type the clamp does not reach keeps its inference.
declare function mapAll<T>(xs: T[], f: (x: T) => string): string[];
export const d = mapAll([new Sub()], (s) => s.extra);

// The clamp still applies with no callback at all (the pre-existing path).
declare function pair<T extends Base>(cls: new (...args: never[]) => T, v: T): T;
declare const s: Sub;
export const e = pair(Sub, s);
