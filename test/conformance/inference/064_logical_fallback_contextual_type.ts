// The RIGHT operand of `||` / `??` is contextually typed by the TYPE OF THE
// LEFT OPERAND whenever the expression itself has no contextual type (tsc's
// `getContextualTypeForBinaryOperand`). That is what keeps a fallback object
// literal's property at its literal type — `{ type: "selection" }`, not the
// widened `{ type: string }` — and so keeps the result a two-member union
// instead of collapsing it into the fallback's widened shape, which is a
// supertype of the left operand. `&&` gets no such treatment: only an outer
// contextual type reaches its right operand.

type ToolType = "selection" | "rectangle" | "eraser";
type ActiveTool = { type: ToolType; locked: boolean };

declare const last: ActiveTool | null;

// 1. `||`: the fallback keeps `type: "selection"`, so the result is
//    `ActiveTool | { type: "selection" }` and the shared property is a
//    `ToolType` — not the widened `string`.
const a = last || { type: "selection" };
export const a1: ToolType = a.type;

// `locked` still exists on only one arm of that union.
export const a2 = a.locked; // TS2339

// 2. `??` behaves identically.
const b = last ?? { type: "selection" };
export const b1: ToolType = b.type;

// 3. The left operand has no `type` property, so nothing admits the literal
//    and the fallback widens exactly as it did before.
declare const other: { zzz: number } | null;
const c = other || { type: "selection" };
export const c1: ToolType = c.type; // TS2339 (`type` is missing on `{ zzz: number }`)

// 4. A contextual *signature* reaches the fallback arrow through the left
//    operand, so `n` is `number` rather than an implicit `any`.
declare const f: ((n: number) => string) | undefined;
const g = f || ((n) => {
  const bad: string = n; // TS2322 — `n` really is `number`
  return bad;
});
export const g1: string = g(1);

// 5. `&&` is asymmetric: its right operand is NOT contextually typed by the
//    left, so the fallback's property widens to `string`.
const k = last && { type: "selection" };
export const k1: ToolType = k ? k.type : "selection"; // TS2322

// 6. Contextual typing alone never triggers an excess-property check: the
//    fallback may carry properties the left operand does not have.
const m = last || { type: "selection", extra: 1 };
export const m1 = m;

// 7. The fallback is still *checked* where the whole expression is used.
declare function want(x: ActiveTool): void;
want(last || { type: "selection" }); // TS2345 — `locked` is missing
