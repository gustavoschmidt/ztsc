// A union is callable when every constituent is. The per-constituent test
// handled functions, overload sets and callable objects; a constituent that
// was itself an INTERSECTION fell to the arm that says "not callable", so a
// union with one intersection member in it reported TS2349 as a whole.
//
// The top-level callee already walks an intersection looking for the member
// that carries the signatures (that is how `function F(){} + namespace F {}`
// resolves). A union constituent gets the same walk.
//
// The shape in the wild is `Document | (Window & typeof globalThis)` — the
// element of a DOM event-target union — which is why the whole
// `target?.addEventListener?.(…)` helper failed.

type Fn = (x: number) => number;
type Tagged = { tag: string };

declare const a: Fn | (Fn & Tagged);
export const callIntersectionMember = a(1);

declare const b: ((x: number) => number) & Tagged;
export const callBareIntersection = b(2);

// The intersection carries its call signature on an OBJECT member rather than
// as a bare function type.
type CallableObject = { (x: number): number; kind: "co" };
declare const c: Fn | (CallableObject & Tagged);
export const callObjectMember = c(3);

// An overload set inside the intersection.
type Overloaded = { (x: number): number; (x: string): string };
declare const d: Fn | (Overloaded & Tagged);
export const callOverloadMember = d(4);

// An intersection with no callable member keeps the error.
declare const e: Fn | (Tagged & { other: number });
export const notCallable = e(5);

// Optional call through the union, which is how the DOM shape is written.
declare const f: (Fn & Tagged) | undefined;
export const optionalCall = f?.(6);

// The gathered signatures are really used: the call's result is the
// intersection member's return type, not `any`.
declare const g: Fn | (Fn & Tagged);
export const rightReturn: number = g(6);
export const wrongReturn: string = g(7);
