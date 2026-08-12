// Every write below is REFLEXIVE — the source is the element union itself, or one
// of its arms — so the whole case must be clean.
//
// The relation that decides them is `intersection source -> lazy ref to a union`:
// `typeRelatedToSomeType` walks the element union's members, reaches the
// unexpanded `Variant` ref, and hands the pair each intersection-shaped source.
// Answering that without expanding the reference (`structuralAssignable`, whose
// first line requires an object target) rejected all three arms, so assigning
// `(Variant | Group | Sep)[]` to the very `children` slot it was written for
// failed — while the same union spelled out inside this module, or rebuilt by a
// distributive conditional, succeeded.
import type { Branch, Group, Leaf, Link, Sep, Variant } from "./tree";

// Touch the UNION end of the cycle first, as an importer naturally does.
declare const v: Variant;
export const z0 = v;

declare const elems: (Variant | Group | Sep)[];
declare const leaves: Leaf[];
declare const links: Link[];
declare const branches: Branch[];
declare const groups: Group[];
declare const seps: Sep[];

export function mkRoot(items: (Variant | Group | Sep)[]): Branch {
  return { kind: "node", id: "x", variant: "branch", children: items };
}

export const z1: Branch["children"] = elems;
export const z2: Branch["children"] = leaves;
export const z3: Branch["children"] = links;
export const z4: Branch["children"] = branches;
export const z5: Branch["children"] = groups;
export const z6: Branch["children"] = seps;

export const z7: Variant | Group | Sep = leaves[0];
export const z8: Variant | Group | Sep = branches[0];
export const z9: Variant = branches[0];
