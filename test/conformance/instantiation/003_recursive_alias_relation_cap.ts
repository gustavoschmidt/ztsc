// Regression guard for the structural-relation recursion cap (see
// `max_relation_depth` in src/checker.zig). `Grow<T>` re-expands with a fresh,
// distinct type argument on every hop, so `isAssignable` walks (via its
// deferred-conditional / `ref` arms) an unbounded chain of distinct interned
// types that neither the relation memo nor the ref-expansion memo can break —
// before the cap this stack-overflowed (bus error) inside `containsMappedParam`
// / `isAssignable`. This is the minimal shape of the react-hook-form
// `PathValueImpl` recursion that crashed a real dogfood project.
//
// Differential note: tsc reports `TS2589` here (excessively deep). ztsc's cap
// instead assumes the relation and stays silent — a deliberate, deterministic
// UNDER-REPORT (project under-report policy), never a false positive. Emitting
// TS2589 at the cap would false-positive genuinely-valid deep recursive types
// that tsc accepts (e.g. real react-hook-form forms), so the snapshot below is
// empty: the case exists to ensure this input keeps *checking without crashing*
// and deterministically. If the cap regresses, this case stack-overflows and
// the suite crashes.
type Grow<T> = T extends object ? `${keyof T & string}` | Grow<{ deeper: T }> : never;
declare const s: string;
const p: Grow<{ a: number }> = s;
