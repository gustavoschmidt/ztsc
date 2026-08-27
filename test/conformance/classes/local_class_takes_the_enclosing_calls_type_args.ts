// A class declared inside a generic is parameterized by the generic's own
// type parameters (tsc's `outerTypeParameters`), so `typeof Inner` names a
// FAMILY and the call that produced it picks the member.

// The static-read half: `outer(5)` fills `T` with `number`, so the static
// read off the returned constructor is `number` and not `T`.
function outer<T>(x: T) {
    class Inner {
        static y: T = x;
    }
    return Inner;
}
let ok: number = outer(5).y;
let bad: string = outer(5).y;

// The heritage half: the arguments ride on the class VALUE, so a derived
// class inherits the members already filled in.
class Base<T> {
    v: T;
    constructor(v: T) {
        this.v = v;
    }
}
function mk<U>(u: U) {
    return class extends Base<U> {
        constructor() {
            super(u);
        }
    };
}
class K extends mk(1) {}
let ok2: number = new K().v;
let bad2: string = new K().v;

// …and a heritage clause may still write the base's OWN arguments: `W` comes
// from the class value, `TInner` from the reference.
function mk2<W>(w: W) {
    return class Inner2<TInner> extends Base<W> {
        constructor(public t: TInner) {
            super(w);
        }
    };
}
let inner2 = mk2(1);
class S extends inner2<string> {
    constructor() {
        super("s");
    }
}
let ok3: number = new S().v;
let ok4: string = new S().t;
let bad3: number = new S().t;
