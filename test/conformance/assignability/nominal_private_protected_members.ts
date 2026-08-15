// The one NOMINAL rule inside the structural relation: tsc's
// `private`/`protected` screen in `propertiesRelatedTo`, which compares the two
// property symbols' DECLARATIONS before it relates a single member type. Two
// classes that each declare `private a: string` are unrelated however identical
// their members, because a private member is only ever the one its own class
// declared.
//
// Every line below is oracle-verified against tsgo 7.0.2, negatives included:
// the rule is nominal, so what it must NOT reject is as load-bearing as what it
// must. See `src/checker/nominal_members.zig`.

// --------------------------------- 1. both sides private, separate declarations
class A2 {
    private a: string = "";
}
class B2 {
    private a: string = "";
}
declare var a2: A2;
declare var b2: B2;
declare var sinkA2: A2;
sinkA2 = b2; // TS2322: separate declarations of a private property
a2 < b2; // TS2365
a2 === b2; // TS2367

// The COMPARABLE relation runs the same screen — it is `propertiesRelatedTo`,
// shared by every relation — so the comparison operators report too, in both
// directions.
b2 > a2; // TS2365
b2 !== a2; // TS2367

// --------------------------------- 2. both sides protected, no derivation
class A3 {
    protected a: string = "";
}
class B3 {
    protected a: string = "";
}
declare var b3: B3;
declare var sinkA3: A3;
sinkA3 = b3; // TS2322: protected, and B3 is not derived from A3

// --------------------------------- 3. NEGATIVE: one inherited declaration
// `class D extends A2 {}` resolves `a` to A2's own member symbol from both
// sides, so tsc's `sourceProp !== targetProp` guard skips the rule entirely.
class D2 extends A2 {}
declare var d2: D2;
sinkA2 = d2; // ok

// A protected member accepts a source from a class DERIVED from the declaring
// one (`isValidOverrideOf`), which is the asymmetry the access-site rule has.
class D3 extends A3 {}
declare var d3: D3;
sinkA3 = d3; // ok

// The derived class RE-DECLARING the private member is its own declaration, and
// is rejected in both directions.
class R2 extends A2 {
    private a: string = "";
}
declare var r2: R2;
sinkA2 = r2; // TS2322
declare var sinkR2: R2;
sinkR2 = a2; // TS2322

// --------------------------------- 4. NEGATIVE: public members stay structural
class P1 {
    a: string = "";
}
class P2 {
    a: string = "";
}
declare var p2: P2;
declare var sinkP1: P1;
sinkP1 = p2; // ok

// --------------------------------- 5. one side private, one side public
class Q1 {
    private a: string = "";
}
declare var q1: Q1;
declare var litA: { a: string };
litA = q1; // TS2322: private in Q1, not in the literal
declare var sinkQ1: Q1;
sinkQ1 = litA; // TS2322: the SAME message, whichever way the assignment runs

// --------------------------------- 6. protected source, public target
class Q2 {
    protected a: string = "";
}
declare var q2: Q2;
litA = q2; // TS2322: protected in Q2 but public in the literal

// --------------------------------- 7. an INTERFACE inherits the declaration
// `interface I extends A2` inherits A2's private `a`, and the declaring symbol
// is still A2's — so it relates to A2, and not to B2.
interface I2 extends A2 {
    z: number;
}
declare var i2: I2;
sinkA2 = i2; // ok
declare var sinkB2: B2;
sinkB2 = i2; // TS2322

// --------------------------------- 8. NEGATIVE: the screen is per PROPERTY
// A private member the target does not declare at all is not compared, so a
// class with private state is still assignable to its public surface.
class S1 {
    private secret: string = "";
    open: number = 1;
}
declare var s1: S1;
declare var litOpen: { open: number };
litOpen = s1; // ok

// --------------------------------- 9. generic classes, per instantiation
class G1<T> {
    private v!: T;
}
class G2<T> {
    private v!: T;
}
declare var g1s: G1<string>;
declare var g1n: G1<number>;
declare var sinkG1s: G1<string>;
declare var sinkG2s: G2<string>;
sinkG1s = g1s; // ok — same declaration, same argument
sinkG1s = g1n; // TS2322 — same declaration, wrong argument
sinkG2s = g1s; // TS2322 — separate declarations of a private property

// --------------------------------- 10. nested, through a property
declare var boxB2: { p: B2 };
declare var sinkBoxA2: { p: A2 };
sinkBoxA2 = boxB2; // TS2322
