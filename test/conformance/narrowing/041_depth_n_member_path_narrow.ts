// Depth-N reference narrowing: the flow-narrowing reference key tracks member
// paths (`a.b`, `a.b.c`, `this.x.y`) up to depth 3, not just a root symbol or
// a single property. A guard on a deep path narrows subsequent reads of the
// same path; writing any prefix of the path invalidates the whole subtree; a
// different branch does not inherit the narrowing; and paths deeper than the
// cap are simply not tracked (sound under-narrowing, no crash). Minimized
// repros of dogfood-project deep-guard shapes (e.g. a service reading
// `this.device.gatt` after `this.device?.gatt?.connected`, and container code
// reading `data.property.attributes` after an `attributes &&` guard).

interface Leaf {
  tag: "a" | "b";
  a?: number;
  b?: number;
}
interface Inner {
  leaf?: Leaf;
  kind: "one" | "two";
  val: number | undefined;
}
interface Mid {
  inner?: Inner;
}
interface Outer {
  mid: Mid;
  name: string | number;
}

// POSITIVE (must NOT error) --------------------------------------------------
// Depth-2 truthiness: `o.mid.inner` guarded non-undefined.
function p_truthy(o: Outer) {
  if (o.mid.inner) {
    return o.mid.inner.kind; // OK: inner narrowed to Inner
  }
  return "";
}

// Depth-2 optional-chain containment: a truthy `o.mid.inner?.kind` implies the
// receiver `o.mid.inner` did not short-circuit.
function p_optchain(o: Outer) {
  if (o.mid.inner?.kind) {
    return o.mid.inner.val; // OK: inner is non-undefined here
  }
  return undefined;
}

// Depth-2 discriminant: narrow the union member `o.mid.inner` by `.kind`.
function p_discriminant(o: Outer) {
  if (o.mid.inner && o.mid.inner.kind === "one") {
    return o.mid.inner.val; // OK
  }
  return undefined;
}

// Depth-3 truthiness: `o.mid.inner.leaf` guarded non-undefined (path length 3).
function p_depth3(o: Outer) {
  if (o.mid.inner && o.mid.inner.leaf) {
    return o.mid.inner.leaf.tag; // OK: leaf narrowed to Leaf
  }
  return "a" as const;
}

// Depth-2 typeof guard: `typeof o.name === "string"` narrows `o.name` at depth 1
// while the deep guard machinery stays inert for the shorter path.
function p_typeof(o: Outer) {
  if (typeof o.name === "string") {
    return o.name.length; // OK: string
  }
  return 0;
}

// NEGATIVE CONTROLS (MUST error) ---------------------------------------------
// No guard: deep read of a possibly-undefined path.
function n_noguard(o: Outer) {
  return o.mid.inner.kind; // error TS18048: o.mid.inner possibly undefined
}

// Prefix reassignment invalidates the narrowing: writing `o.mid.inner` re-widens
// (here reset by overwriting the whole `o.mid` prefix).
function n_prefix_write(o: Outer, fresh: Mid) {
  if (o.mid.inner) {
    o.mid = fresh; // invalidates o.mid.inner narrowing
    return o.mid.inner.kind; // error TS18048: re-widened to Inner | undefined
  }
  return "";
}

// Different branch does not inherit the narrowing.
function n_other_branch(o: Outer) {
  if (o.mid.inner) {
    return o.mid.inner.kind; // OK
  }
  return o.mid.inner.val; // error TS18048: else branch, inner still undefined
}

// Wrong discriminant branch: narrowed to the "two" member, read is still fine
// but the negative here is reading a Leaf-only prop off the un-narrowed leaf.
function n_deep_optional(o: Outer) {
  if (o.mid.inner) {
    return o.mid.inner.leaf.tag; // error TS18048: leaf possibly undefined
  }
  return "a" as const;
}
