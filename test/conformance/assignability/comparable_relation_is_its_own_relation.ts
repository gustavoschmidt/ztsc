// The COMPARABLE relation is a relation, not assignability with patches. tsc
// threads `relation` through every one of its relation functions and gives each
// its own pair cache; ztsc threads `Checker.rel_kind` and folds it into the
// pair memo's key. Three rules read it, and each is exercised here in both the
// positive and the negative direction. Every line is oracle-verified against
// tsgo 7.0.2.

class Base {
    a!: string;
}
class Derived extends Base {
    b!: string;
}
class C {
    c!: string;
}

// ------------------------------------- 1. a union SOURCE distributes EXISTENTIALLY
// `someTypeRelatedToType` where assignability uses `eachTypeRelatedToType`. An
// OPTIONAL parameter is `T | undefined`, so `undefined` is the overlap that
// makes two otherwise-unrelated parameter types comparable.
declare var a5: {fn(a?: Base): void};
declare var b5: {fn(a?: C): void};
var r5lt = a5 < b5; // ok
var r5gt = b5 > a5; // ok
var r5eq = a5 === b5; // ok
var r5ne = b5 !== a5; // ok

// The negative control: REQUIRED parameters of the same two unrelated types
// have no union to distribute over, so there is no overlap.
declare var q5: {fn(a: Base): void};
declare var p5: {fn(a: C): void};
var rq5lt = q5 < p5; // TS2365
var rq5eq = q5 === p5; // TS2367

// A union source is still ASSIGNABLE only when EVERY constituent fits — the
// existential rule must not leak into assignability.
declare var u5: Base | C;
const asBase: Base = u5; // TS2322

// ------------------------------------- 2. eraseGenerics
// `eraseGenerics = relation === comparableRelation`: a generic signature is
// erased to `any` rather than instantiated in the target's context, so two
// generic methods that are assignable in NEITHER direction still overlap.
declare var a7: {fn<T>(t: T): T};
declare var b7: {fn<T>(t: T[]): T};
var r7lt = a7 < b7; // ok
var r7eq = a7 === b7; // ok

// The negative control: assignability still instantiates, so neither direction
// relates (this is the rule 82f2209 made authoritative).
const a7AsB7: {fn<T>(t: T[]): T} = a7; // TS2322
const b7AsA7: {fn<T>(t: T): T} = b7; // TS2322

// ------------------------------------- 3. the type-parameter carve-out
// An unconstrained parameter is comparable to anything, because it could be
// instantiated to the other operand's type — EXCEPT against another type
// parameter, where tsc takes the leniency back ("forbid comparing a type
// parameter with another type parameter unless one extends the other").
function twoParams<T, U>(t: T, u: U) {
    var lt = t < u; // TS2365
    var eq = t === u; // TS2367
    var same = t === t; // ok — one parameter against itself
}

function oneExtendsTheOther<T, V extends T>(t: T, v: V) {
    var lt = v < t; // ok
    var eq = v === t; // ok
    var lt2 = t < v; // ok — either direction of the chain counts
}

// A parameter against a CONCRETE type keeps the leniency in both operators.
function paramVsConcrete<T>(t: T, s: string, o: {a: string}) {
    var lt = t < s; // ok
    var eq = t === o; // ok
}

// A CONSTRAINED parameter still rejects a genuinely disjoint operand.
function constrained<T extends 'a' | 'b'>(t: T) {
    var eq = t === 'zzz'; // TS2367
}
