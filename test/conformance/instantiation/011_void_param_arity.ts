// A source call signature whose trailing parameter has type `void` is
// callable with zero arguments — tsc's `getMinArgumentCount` walks back from
// the last required parameter and drops any trailing parameter that accepts
// `void`. Such a signature is therefore assignable to a nullary function
// type. Models redux-toolkit's `ActionCreatorWithoutPayload`, a generic
// *interface* carrying a `(noArgument: void) => …` call signature; the fix
// must survive instantiation of that interface.
interface Tag<T extends string> {
  type: T;
}
interface VoidCall<T extends string = string> extends Tag<T> {
  (noArgument: void): T;
}
declare const vc: VoidCall<"x">;

const a: () => void = vc; // clean: void param dropped; "x" ret -> void ok
const b: () => unknown = vc; // clean
const c: () => string = vc; // clean: ret "x" <: string
const d: () => number = vc; // TS2322: "x" ret not number

// Plain function form of the same rule.
declare const f: (x: void) => number;
const g: () => void = f; // clean
const h: () => number = f; // clean

// The rule is narrow: a required non-void parameter still fails arity.
declare const p: (x: number) => void;
const q: () => void = p; // TS2322: p requires an argument

// A trailing void param after a real one is still dropped.
declare const r: (x: number, y: void) => void;
const s: (x: number) => void = r; // clean
