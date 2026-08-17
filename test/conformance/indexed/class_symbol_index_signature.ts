// A class BODY's `[k: symbol]: V` is a symbol-keyed index signature, so it
// constrains symbol-named members and nothing else — and it constrains them
// wherever the pair meets: both in one body, the index derived, the index
// inherited.

class Own {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
    [s: symbol]: () => { x: number };
}

class BaseMember {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
}
class IndexInDerived extends BaseMember {
    [s: symbol]: () => { x: number };
}

class BaseIndex {
    [s: symbol]: () => { x: number };
}
class MemberInDerived extends BaseIndex {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
}

// A symbol index does not constrain string- or number-named members.
class Unconstrained {
    ok = "";
    3 = true;
    [s: symbol]: () => { x: number };
}

// ...and a satisfied one says nothing.
class Satisfied {
    [Symbol.toStringTag]() {
        return { x: 0 };
    }
    [s: symbol]: () => { x: number };
}

// A `string` index written beside a `symbol` one takes the key domain back,
// so the STRING members are the ones judged.
class StringWins {
    bad = true;
    [s: symbol]: string;
    [k: string]: string;
}

export { Own, IndexInDerived, MemberInDerived, Unconstrained, Satisfied, StringWins };
