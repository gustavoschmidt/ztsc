// A type parameter constrained by itself. `propOfTypeIdx`'s `.type_param` arm
// followed the constraint chain by RE-ENTERING itself once per hop, so a
// constraint that cycles back recursed until the stack died. It now walks the
// chain iteratively with the same fixpoint break and 8-hop bound its
// neighbours `indexObjBaseConstraint` / `transitiveBaseConstraint` use, and a
// circular constraint answers "no apparent members" — tsc's
// `getBaseConstraintOfType`, which is undefined for a circular constraint.
//
// The property reads below are what force the apparent-type walk; the TS2339s
// are the oracle's own answer for them, and the TS2313s from the declaration
// check over the type-parameter list (`checkFileCircularConstraints`). What
// this case gates is that the reads terminate.

// Direct self-reference.
function direct<T extends T>(p: T) {
    return p.missing;
}

// A two-hop cycle, which the fixpoint break alone does not catch.
function twoHop<T extends U, U extends T>(p: T) {
    return p.missing;
}
