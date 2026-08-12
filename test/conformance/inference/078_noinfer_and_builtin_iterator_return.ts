// The two `intrinsic` type aliases the lib declares besides the four string
// transforms, both of which ztsc used to resolve to `any`.
//
//   type NoInfer<T> = intrinsic;              (lib.esnext.0.d.ts)
//   type BuiltinIteratorReturn = intrinsic;   (lib.esnext.1.d.ts)
//
// `NoInfer<T>` IS `T` — tsc's substitution-type marker — and the only thing
// that reads the marker is inference, which adds no candidate from it. As
// `any` it silently accepted every argument written at such a position.
//
// `BuiltinIteratorReturn` is the `TReturn` of every built-in iterator, and is
// `undefined` under `strictBuiltinIteratorReturn` (implied by `strict`, the
// only mode ztsc runs). As `any` it erased the `| undefined` from every
// `next().value`.
//
// Types are revealed through an assignment error rather than read off a hover:
// a contextual return type would infer the parameter by itself.

// --- NoInfer ----------------------------------------------------------
declare function pair<T>(a: T, b: NoInfer<T>): T;
pair("a", "b"); // T is "a" from `a` alone; "b" does not fit it
pair<string>("a", "b"); // written explicitly: both fit

declare function only<T extends string>(a?: NoInfer<T> | null): T[];
const onlyR = only("x"); // no candidate at all -> T falls to its constraint
export const onlyBad: number = onlyR;

declare function plain<T extends string>(a?: T | null): T[];
const plainR = plain("z"); // the same signature WITHOUT the marker
export const plainBad: number = plainR;

// A concrete argument needs no marker and keeps behaving as itself.
declare function conc(a: NoInfer<string>): void;
conc(1);

// --- BuiltinIteratorReturn --------------------------------------------
const setIter = new Set([1, 2]).values();
export const setVal: number = setIter.next().value;

const mapIter = new Map([["a", 1]]).entries();
export const mapVal: [string, number] = mapIter.next().value;

const arrIter = [1, 2].values();
export const arrVal: number = arrIter.next().value;

// `done` still discriminates the result, so a guarded read has no `undefined`.
export function guardedRead(): string {
  const r = new Set(["s"]).values().next();
  if (r.done) {
    return "";
  }
  return r.value;
}
