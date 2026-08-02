// `const` does not suspend the CONSTRAINT: the kept literal still has to
// satisfy it, and where the constraint forces a wider shape the wider shape is
// what the parameter takes. It also does not suspend the ordinary argument
// check — a `const` parameter is only about how a literal is READ.

interface Shape {
    kind: string;
}

declare function konst<const T extends Shape>(x: T): T;

// The literal is kept AND satisfies the constraint.
const ok = konst({ kind: "circle" });
const bad_ok: { kind: "square" } = ok;

// NEGATIVE — the constraint still rejects. (A fresh object LITERAL that misses
// the constraint gets tsc's excess-property phrasing TS2353, and a MISSING
// property its TS2741 elaboration head; neither is a distinction ztsc draws,
// so the negative is a present-but-wrong property, where both agree.)
declare const notShape: { kind: number };
konst(notShape);

// A literal-union constraint: `const` and the constraint agree, and the
// literal survives either way.
declare function pick<const K extends "a" | "b">(k: K): K;
const p = pick("a");
const bad_p: "b" = p;

// NEGATIVE — outside the constraint.
pick("c");

// A `const` parameter constrained to a STRING keeps a template expression's
// template-literal type, as an `extends string` constraint alone already does.
declare const idx: number;
declare function key<const K extends string>(k: K): K;
const k = key(`p.${idx}`);
const bad_k: "p.0" = k;

// Unconstrained `const` reaches the same answer through the const context
// rather than through the constraint.
declare function key2<const K>(k: K): K;
const k2 = key2(`p.${idx}`);
const bad_k2: "p.0" = k2;

// A CLASS may declare `const` type parameters; the constructor call is the
// inference site.
declare class Holder<const T> {
    constructor(value: T);
    value: T;
}
const h = new Holder([1, 2]);
const bad_h: Holder<[3]> = h;

// A METHOD may too, including on an already-generic class.
declare class Registry<E> {
    add<const N extends string>(name: N, entry: E): N;
}
declare const reg: Registry<number>;
const added = reg.add("alpha", 1);
const bad_added: "beta" = added;

// NEGATIVE — the method's ordinary parameter is unaffected.
reg.add("alpha", "not-a-number");
