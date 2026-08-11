// An `extends` clause is not proof of assignability. A derived class that
// REDECLARES an inherited member at a type the base's does not accept is not
// assignable to its own base, and every use of it says so — the declaration
// diagnostic (TS2415/TS2416) is a report, not a repair.
//
// The generic in the middle is what makes the pair unrelated: `Store<T>`
// mentions `T` in a parameter of an arrow-initialised FIELD (contravariant
// under strictFunctionTypes) and in its return (covariant), so `T` is
// INVARIANT and `Store<Sub>` does not relate to `Store<Base>` in either
// direction. It also makes the walk CYCLIC — `Base.store: Store<Base>` and
// `Sub.store: Store<Sub>` refer back to their owners — so a co-inductive
// structural walk that assumes the pair on the stack confirms its own
// assumption unless the variance verdict cuts it off.
class Store<T> {
  add = (i: T): T => i;
}

class Base {
  id = "";
  store!: Store<Base>;
}

class Sub extends Base {
  name = "";
  declare store: Store<Sub>;
}

declare const s: Sub;
export const a1: Base = s;

// The same question one level in.
declare const st: Store<Sub>;
export const a2: Store<Base> = st;

// Control: a subclass that only ADDS members stays assignable to its base,
// which is what the nominal-heritage fast path is for.
class Adds extends Base {
  extra = 1;
}
declare const adds: Adds;
export const a3: Base = adds;

// Control: redeclaring with the SAME type is still assignable.
class Same extends Base {
  declare store: Store<Base>;
}
declare const same: Same;
export const a4: Base = same;

// Control: a METHOD-syntax member is compared bivariantly, so the generic is
// bivariant in `T` and the two instantiations relate.
class MStore<T> {
  add(_i: T): void {}
}
class MBase {
  store!: MStore<MBase>;
}
class MSub extends MBase {
  name = "";
  declare store: MStore<MSub>;
}
declare const ms: MSub;
export const a5: MBase = ms;

// Two levels of heritage: the redeclaration is on the MIDDLE class, so the
// bottom one is unrelated to the top one too.
class Mid extends Base {
  declare store: Store<Sub>;
}
class Bottom extends Mid {
  more = 2;
}
declare const bottom: Bottom;
export const a6: Base = bottom;
