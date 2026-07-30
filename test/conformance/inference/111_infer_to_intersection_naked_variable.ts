// tsc's `inferToMultipleTypes` naked-type-variable rule: when an inference
// TARGET is an intersection with exactly ONE constituent that is a bare
// inference variable, the whole source infers to that variable once the
// non-variable constituents have been inferred through.
//
// ztsc paired an intersection parameter's constituents against the argument's
// by structural kind, and a naked type parameter deliberately pairs with
// nothing (it would swallow whichever constituent came first). Nothing else
// paired either — a mapped parameter never pairs with an object argument — so
// `CR` took no candidate at all and fell back to its constraint, whose `keyof`
// is `string`.
//
// This is redux-toolkit's `createSlice` parameter shape:
// `ValidateSliceCaseReducers<S, ACR> = ACR & { [T in keyof ACR]: … }`.

type Validated<ACR> = ACR & { [T in keyof ACR]: {} };

declare function take<CR extends Record<string, (s: number) => void>>(o: {
  reducers: Validated<CR>;
}): { keys: keyof CR };

const r = take({ reducers: { a(s: number) {}, b(s: number) {} } });

const ok: "a" | "b" = r.keys;

// The written keys, not the constraint's `string`.
const bad: "a" = r.keys;

// A brand-style intersection still infers through the constituent that carries
// the variable, and the naked rule does not fire (two variables, no single one).
type Branded<A, B> = A & B & { _brand: "x" };
declare function pair<X, Y>(v: Branded<X, Y>): [X, Y];
declare const bx: Branded<{ a: number }, { b: string }>;
const p = pair(bx);
const p0: { a: number } = p[0];

export { ok, bad, p0 };
