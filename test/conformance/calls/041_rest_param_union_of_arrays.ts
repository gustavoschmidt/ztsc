// A rest parameter may be typed by a *union* of array types. Each argument
// position then has the union of their element types — tsc's
// `getIndexedAccessType(restType, number)` distributes — so a callback
// argument is contextually typed and its parameters are not implicit `any`.
// Collapsing the union to `any` left every such argument untyped.
type Sub<T extends any[]> = (...payload: T) => void;

declare class Emitter<T extends any[] = []> {
  on(...handlers: Sub<T>[] | Sub<T>[][]): () => void;
}

declare const e: Emitter<[increment: { x: number }]>;

// Contextually typed from the `Sub<T>[]` constituent.
export const un = e.on((increment) => {
  const n: number = increment.x;
  return n;
});

// The other constituent of the position — an array of handlers — is accepted
// at the same position.
declare const many: Sub<[{ x: number }]>[];
export const un2 = e.on(many);

// NEGATIVE: per-position element types are not a licence to mix
// constituents — the argument list as a whole still has to satisfy one arm.
export const un3 = e.on((a) => a.x, many, (b) => b.x);

// NEGATIVE: the union of element types is still checked. A callback whose
// parameter is not compatible with either constituent is rejected.
export const bad = e.on((s: string) => s.length);

// Control: a plain (non-union) array rest is unchanged.
declare function each(...handlers: Sub<[{ y: string }]>[]): void;
export const ok = each((h) => h.y.length);

// Tuple rest is unchanged too — it expands positionally.
declare function pair(...args: [a: number, b: string]): void;
export const ok2 = pair(1, "x");
