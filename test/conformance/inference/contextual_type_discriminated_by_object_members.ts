// tsc's `discriminateContextualTypeByObjectMembers`: a union contextual type
// is collapsed to the one constituent the literal's own discriminant
// properties select, BEFORE any property reads it. Without that step every
// callback in a discriminated-union literal has a union contextual type whose
// constituents disagree, and `getContextualSignature` hands over nothing.
//
// Each parameter is pinned from BOTH sides — accepted as the type the winning
// constituent gives it, rejected as the loser's — because a snapshot records
// only the code and the line.

type ADT =
    | { kind: "a"; method(x: string): number }
    | { kind: "b"; method(x: number): string };

declare function invoke(item: ADT): void;

invoke({
    kind: "a",
    method(a) {
        const ok: string = a;
        const bad: number = a; // TS2322
        return +a;
    },
});

// The discriminant written as a shorthand property (an identifier value).
const kind = "a";
invoke({
    kind,
    method(a) {
        const ok: string = a;
        const bad: number = a; // TS2322
        return +a;
    },
});

// An evaluatable template expression is a discriminant value too.
type S = { d: "s"; cb: (x: string) => void };
type N = { d: "n"; cb: (x: number) => void };
declare function foo(x: S | N): void;
foo({
    d: `${"s"}`,
    cb: (x) => {
        const ok: string = x;
        const bad: number = x; // TS2322
    },
});

// An OPTIONAL discriminant is `T | undefined`, so a `href?: never` sibling is
// discriminated away by a `string` value.
type Link = { href: string; onClick?: (e: string) => void };
type Button = { href?: never; onClick?: (e: number) => void };
const b: Link | Button = {
    href: `2${1}3`,
    onClick: (e) => {
        const ok: string = e;
        const bad: number = e; // TS2322
    },
};

// The contextual type of a property is what the target DECLARES — never a
// member the global `Function` interface lends every value — so the function
// constituent contributes no `apply` and the object one's signature stands
// alone.
declare class Compiler {
    compile(): void;
}
interface PluginInstance {
    apply: (compiler: Compiler) => void;
}
type PluginFunction = (this: Compiler, compiler: Compiler) => void;
const p: PluginInstance | PluginFunction = {
    apply: (compiler) => {
        const ok: Compiler = compiler;
        const bad: number = compiler; // TS2322
    },
};
