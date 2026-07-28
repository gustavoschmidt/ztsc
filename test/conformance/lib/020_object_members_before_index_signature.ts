// A string index signature is the LAST thing consulted for a named property,
// after the object's own members and after the apparent members of the global
// `Object` (and `Function`, for a callable object).
//
// tsc's `getPropertyOfType` never consults an index signature at all — the
// property lookup ends at `getPropertyOfObjectType(globalObjectType, name)`,
// and only `checkPropertyAccessExpression` falls back to an applicable index
// info once that has come back empty. ztsc asked the index signature first, so
// on a type whose index value is a union with a function in it, `hasOwnProperty`
// resolved to the index VALUE and calling it was TS2349 rather than
// `Object.hasOwnProperty`.

type Bag = { [key: string]: string | ((el: string) => string) };

declare const bag: Bag;

// `Object`'s members win over the index signature.
export const owns = bag.hasOwnProperty("k");
export const str = bag.toString();
export const local = bag.toLocaleString();
export const enumerable = bag.propertyIsEnumerable("k");

// A name the index signature does cover still comes from it.
export const value = bag.anythingElse;

// An own member beats both.
type WithOwn = { toString: () => number; [key: string]: unknown };
declare const withOwn: WithOwn;
export const ownWins: number = withOwn.toString();

// A callable object takes `Function`'s members ahead of the index signature
// too.
type CallableBag = {
  (x: number): number;
  [key: string]: unknown;
};
declare const callable: CallableBag;
export const bound = callable.bind(undefined);
export const arity: number = callable.length;

// The index signature is not a substitute for a *required named* property in
// the assignability relation — that rule is `allow_index = false` and is
// unaffected by the reordering.
declare const asDate: Bag;
export const notADate: { x: number } = asDate;

// A numeric-keyed read still goes through the index signature.
export const numeric = bag[0];
