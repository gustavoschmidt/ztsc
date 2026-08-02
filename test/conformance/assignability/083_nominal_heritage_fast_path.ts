// A derived class/interface against a DECLARED base of itself: the relation
// answers those from the heritage chain instead of walking members
// (`nominalHeritageRelated`). The point of this case is that the shortcut
// only fires when the nominal identity really does imply assignability —
// identical type arguments, or an `any` on the target side — and that a
// mismatched instantiation still reports exactly what the structural walk
// reported.

class Box<T> {
    v!: T;
}
class StrBox extends Box<string> {
    extra = 1;
}
class DeepBox extends StrBox {}

function boxNumber(x: Box<number>): void {}
function boxString(x: Box<string>): void {}
function boxAny(x: Box<any>): void {}

function useClasses(sb: StrBox, db: DeepBox): void {
    boxString(sb); // ok: the declared base, same argument
    boxString(db); // ok: two links up the chain
    boxAny(sb); // ok: `any` target argument relates either way
    boxNumber(sb); // TS2345: Box<string> is not Box<number>
    boxNumber(db); // TS2345
}

interface Base<T> {
    v: T;
}
interface Mid<T> extends Base<T> {
    w: number;
}
interface Leaf extends Mid<string> {
    z: boolean;
}

function baseNumber(x: Base<number>): void {}
function baseString(x: Base<string>): void {}
function baseUnknown(x: Base<unknown>): void {}

function useInterfaces(m: Mid<string>, l: Leaf): void {
    baseString(m); // ok
    baseString(l); // ok
    baseUnknown(l); // ok: covariant, decided structurally
    baseNumber(m); // TS2345
    baseNumber(l); // TS2345
}

// The same shape through a type-argument CONSTRAINT, which is the check that
// made the fast path worth having (TS2344).
interface Holder<T extends Base<string>> {
    t: T;
}
type Good = Holder<Leaf>;
type Bad = Holder<Base<number>>; // TS2344

// A base reached only through `implements` is NOT heritage for this purpose:
// it is a separately checked constraint, so the relation still decides it
// structurally — and still decides it correctly.
interface Named {
    name: string;
}
class Person implements Named {
    name = "p";
}
function needsNamed(x: Named): void {}
function usePerson(p: Person): void {
    needsNamed(p); // ok, structurally
}
