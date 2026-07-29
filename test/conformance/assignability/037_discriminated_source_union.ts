// tsc's `typeRelatedToDiscriminatedType`: a source whose DISCRIMINANT property
// is a union is matched against a union target combination-wise. It need not
// fit any single constituent whole — which is also why the fresh-object-literal
// excess check must not demand that it does.
declare const k: "a" | "b";

type T = { type: "a"; x: number } | { type: "b"; x: number } | { type: "c"; y: string };
declare function take(t: T): void;
take({ type: k, x: 1 });
declare const src: { type: "a" | "b"; x: number };
take(src);
export const v: T = { type: k, x: 1 };

// A target constituent may already cover several tags.
type W = { type: "a" | "b" } | { type: "c" };
declare const k2: "a" | "b" | "c";
declare function takeW(t: W): void;
takeW({ type: k2 });

// The constituents may be INTERSECTIONS, with the discriminant in one part and
// the payload in another.
type Base = { x: number; y: number };
type Gen = (Base & { type: "rect" }) | (Base & { type: "diamond" }) | (Base & { type: "ellipse" });
type NonDeleted<T> = T & { isDeleted: false };
declare const t: Gen["type"];
declare const mk: <T extends Gen>(
  ty: T["type"],
) => { x: number; y: number; type: T["type"]; isDeleted: false };
export const f = (): NonDeleted<Gen> => mk<Gen>(t);
