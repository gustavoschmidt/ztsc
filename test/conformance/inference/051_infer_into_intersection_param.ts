// A branded alias materializes to an INTERSECTION, so the *target* of the
// inference is an intersection — the excalidraw geometry shape
// (`LineSegment<P> = [P, P] & { _brand: … }`). The constituents that match
// structurally pair off; the brand object contributes nothing.
type GP = [number, number] & { _brand: "gp" };
type LP = [number, number] & { _brand: "lp" };

type Seg<P extends GP | LP> = [P, P] & { _brand: "seg" };
type Poly<P extends GP | LP> = P[] & { _brand: "poly" };
type Ell<P extends GP | LP> = { center: P; r: number } & { _brand: "ell" };

declare function pointFrom<P extends GP | LP>(x: number, y: number): P;
declare function seg<P extends GP | LP>(a: P, b: P): Seg<P>;
declare function poly<P extends GP | LP>(...p: P[]): Poly<P>;
declare function ell<P extends GP | LP>(center: P, r: number): Ell<P>;

// The contextual type drives `P` through the intersection return type, and
// then through the nested calls that have no inference site of their own.
export const s: Seg<GP> = seg(pointFrom(1, 0), pointFrom(1, 2));
export const p: Poly<GP> = poly(pointFrom(0, 0), pointFrom(1, 1));
export const e: Ell<GP> = ell(pointFrom(0, 0), 3);

// Without a context the constraint still stands.
const sBare = seg(pointFrom(1, 0), pointFrom(1, 2));
export const sBad: Seg<GP> = sBare;

// Inference the other way: an intersection ARGUMENT into a generic
// interface parameter, where only the matching constituent contributes.
declare const g: GP;
declare function firstOf<P extends GP | LP>(x: Seg<P>): P;
declare const sg: Seg<GP>;
export const g1: GP = firstOf(sg);
export const g1bad: LP = firstOf(sg);
export const gg: GP = g;
