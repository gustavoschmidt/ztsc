// TWO union spreads in one literal distribute together — the cartesian product
// of their constituents, bounded on the PRODUCT. Distributing only the first and
// folding the second is the same lost-correlation failure the single-spread
// distribution fixed: the folded half turns every property only some member
// declares optional, and the literal then matches no arm of a discriminated
// target.
//
// The shape is a literal that re-tags a discriminated union through a helper:
// `{ ...prev, ...update(prev), extra }`.

type Sel = { type: "selection"; locked: boolean };
type Arrow = { type: "arrow"; locked: boolean; arrowKind: "elbow" | "sharp" };
type Tool = Sel | Arrow;

declare const prev: Tool;
declare function update(t: Tool): Tool;
declare function wantTool(v: Tool): void;

// POSITIVE (must NOT error) --------------------------------------------------

// Both spreads are two-member unions: 2 x 2 = 4 constituents, each of which is
// one whole arm plus `locked`. Folding either one makes `arrowKind` optional and
// matches neither arm.
export const p1 = wantTool({ ...prev, ...update(prev), locked: true });

// Order does not matter.
export const p2 = wantTool({ ...update(prev), ...prev, locked: false });

// Three union spreads: 2 x 2 x 2 = 8, still under the product bound.
declare function update2(t: Tool): Tool;
export const p3 = wantTool({ ...prev, ...update(prev), ...update2(prev), locked: true });

// A later explicit property still overrides every constituent.
declare function wantSel(v: { type: "selection" | "arrow"; locked: true }): void;
export const p4 = wantSel({ ...prev, ...update(prev), locked: true });

// A property every constituent has is readable off the distributed literal.
export const p5: boolean = { ...prev, ...update(prev) }.locked;

// One union spread next to a NON-union spread is unchanged.
declare const fixed: { extra: null };
export const p6 = wantTool({ ...prev, ...fixed, locked: true });

// A `T | undefined` spread still does not count as distributable (only one
// constituent carries properties), so pairing one with a real union leaves the
// real union distributing alone.
declare const maybe: Sel | undefined;
export const p7 = wantTool({ ...update(prev), ...maybe, locked: true });

// NEGATIVE (must error) ------------------------------------------------------

// Distribution does not invent members.
declare function wantWidth(v: { width: number }): void;
export const n1 = wantWidth({ ...prev, ...update(prev) });

// A property only one constituent has is not readable off the union.
export const n2: string = { ...prev, ...update(prev) }.arrowKind;

// The distributed constituents are still checked: `locked` must be a boolean.
export const n3 = wantTool({ ...prev, ...update(prev), locked: "yes" });
