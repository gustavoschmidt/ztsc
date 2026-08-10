// Two halves of tsc's TS 5.5 inferred type predicate, both about the FALSE
// branch.
//
// 1. `checkIfExpressionRefinesParameter` states its soundness rule as
//
//      const falseSubtype = getFlowTypeOfReference(
//        param.name, initType, trueType, func, falseCondition);
//      return falseSubtype.flags & TypeFlags.Never ? trueType : undefined;
//
//    — the false condition narrows the TRUE TYPE (not the declared type) and
//    must reach `never`.
//
// 2. `getNarrowedTypeWorker`'s assumeFalse arm is
//    `filterType(type, t => !isTypeSubsetOf(t, trueType))`, and for a
//    NON-union subject `isTypeSubsetOf` is identity — so a subject a type
//    predicate narrows to itself is excluded outright.
//
// Together they are what lets `@atproto/api`'s
// `preferences.find(p => asPredicate(validateX)(p))` pick `find`'s guard
// overload. Its element union ends in a bare `{$type: string}` supertype, so
// the old "false branch must not overlap the true type" phrasing could never
// be satisfied, and the true branch is a single intersection, so the
// re-narrow could never reach `never` either.

interface Live {
  $type?: "x#live";
  hideAllFeeds?: boolean;
}
interface P1 {
  $type?: "x#p1";
  a1?: string;
}
type $Typed<V> = V & {$type: string};
type Prefs = $Typed<P1> | $Typed<Live> | {$type: string};

declare function isLive<T>(v: T): v is T & Live;
declare const prefs: Prefs[];

export const found = prefs.find(p => isLive(p));
export const flag: boolean | undefined = found!.hideAllFeeds;

// The plain form still works, and still narrows.
declare function isP1<T>(v: T): v is T & P1;
export const found1 = prefs.find(p => isP1(p));
export const a1: string | undefined = found1!.a1;

// --- what must NOT become a predicate ---------------------------------------
// Truthiness: the falsy branch of `number | null` keeps `number`, so the
// re-narrow does not reach `never` and no predicate is synthesized (`filter`
// keeps its `(number | null)[]` result).
declare const mixed: (number | null)[];
const truthy = mixed.filter(x => !!x);
export const stillNullable: (number | null)[] = truthy;

// `instanceof` is `checkDerived`, a NOMINAL test — the `else` of a guard on a
// structurally identical subclass must keep the declared type, not `never`.
class MaxHiddenRepliesError extends Error {}
export function classify(e: Error) {
  if (e instanceof MaxHiddenRepliesError) {
    return "max";
  } else {
    return e.message;
  }
}
