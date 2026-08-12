// A relation whose spine ALTERNATES between two instantiations of one generic
// rather than growing a bigger one — `Store<Sub>` → `Store<Base>` →
// `Store<Sub>` → … — reached through the parameter position of a property-held
// arrow, which flips the direction at every level.
//
// The alternation is BOUNDED: the set of pairs it visits is finite, so the
// relation's own in-progress mark closes it. `relIdDeeplyNested`
// (`max_relation_identity_repeats`, src/checker.zig) cannot tell it from an
// unbounded one, because its growth test compares each occurrence of a symbol
// with the PREVIOUS occurrence, and `Store<Sub>` followed by `Store<Base>` is
// "later" whenever `Store<Base>` happened to be interned second. It therefore
// cuts at the second link and assumes the pair related, which drops the
// terminal fact at the bottom of the alternation.
//
// Case 1 is decided at the first level and is the control. Cases 2 and 3 need
// the alternation walked and are registered in test/conformance/DEFERRED — see
// the measured cost of every alternative in `max_relation_identity_repeats`.
// Case 3 is the shape outline's `Store<T>.add` actually writes.

// --- 1: the parameter is `T` itself; decided immediately ---------------
class Store1<T> {
    add = (i: T): T => i;
}
class Base1 {
    store!: Store1<Base1>;
    id = "";
}
class Sub1 extends Base1 {
    declare store: Store1<Sub1>;
    name = "";
}
declare const s1: Sub1;
export const b1: Base1 = s1;

// --- 2: the parameter is `Partial<T>`; needs one turn of the alternation
class Store2<T> {
    add = (i: Partial<T>): T => i as T;
}
class Base2 {
    store!: Store2<Base2>;
    id = "";
}
class Sub2 extends Base2 {
    declare store: Store2<Sub2>;
    name = "";
}
declare const s2: Sub2;
export const b2: Base2 = s2;

// --- 3: the parameter is `PartialExcept<T, "id"> | T` (outline's shape) --
type PartialExcept<T, K extends keyof T> = Partial<Omit<T, K>> & Required<Pick<T, K>>;
class Store3<T extends { id: string }> {
    add = (i: PartialExcept<T, "id"> | T): T => i as T;
}
class Base3 {
    store!: Store3<Base3>;
    id = "";
}
class Sub3 extends Base3 {
    declare store: Store3<Sub3>;
    name = "";
}
declare const s3: Sub3;
export const b3: Base3 = s3;
