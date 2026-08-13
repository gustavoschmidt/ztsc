// A getter whose return annotation reads the getter back through `this`.
// `memberTypeOf` DETECTED the circle (it reports TS2502) but only cut it for
// the three shapes that happen to cut below the frame — a field's lazy
// single-member lookup, a method's reserved-signature slot, a field
// initializer. This one has no cut below, so it recursed until the stack
// died. The cut is now tsc's `pushTypeResolution`: a member already being
// resolved answers `any`, and the circle is named once.
declare class C {
    get foo(): typeof this.foo;
}

// The same circle one hop longer, through a second member.
declare class D {
    get a(): typeof this.b;
    get b(): typeof this.a;
}
