// TS2374: two index signatures in one member list claiming the same key domain.
// Reported on EVERY signature of the duplicated set, at the member's first
// token — modifiers included.

class C {
    [x: string]: string;
    [x: string]: string;
}

interface I {
    [x: string]: string;
    [x: string]: string;
}

type Literal = {
    [x: number]: string;
    [x: number]: string;
};

var inline: {
    [x: string]: string;
    [x: string]: string;
};

// Three of a kind: all three are reported, not just the extras.
interface Three {
    [x: string]: string;
    [x: string]: string;
    [x: string]: string;
}

// Modifiers are part of the declaration, so they are where it starts.
interface Modified {
    readonly [x: string]: string;
    readonly [x: string]: string;
}

// Distinct key domains are not duplicates.
interface Distinct {
    [x: string]: string;
    [x: number]: string;
}

// `static [k: …]` lives on the class VALUE's type, which the rule never reads:
// two statics are accepted, and a static beside an instance one is not a pair.
class Statics {
    static [x: string]: string;
    static [x: string]: string;
}
class StaticBesideInstance {
    static [x: string]: string;
    [x: string]: string;
}

// A template-literal key domain is compared like any other.
type Template = {
    [x: `a${string}`]: string;
    [x: `a${string}`]: string;
};

export { C, Statics, StaticBesideInstance, inline };
export type { I, Literal, Three, Modified, Distinct, Template };
