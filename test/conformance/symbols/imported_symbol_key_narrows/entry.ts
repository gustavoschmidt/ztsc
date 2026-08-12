// tsc resolves an element-access key through import aliases before asking
// whether it is a `const` (`tryGetNameFromEntityNameExpression` →
// `resolveEntityName`), so an IMPORTED `unique symbol` keys a tracked
// reference exactly like a locally declared one — which is how outline guards
// `users[PAGINATION_SYMBOL]` in a file other than the one that declares it.
import { PAGINATION, OTHER, Paged } from "./keys";

declare const page: Paged;

export function guardNarrowsAnImportedKey() {
  if (page[PAGINATION]) {
    return page[PAGINATION].total;
  }
  return 0;
}

// Negative controls: the unguarded read stays optional, and a guard on one
// imported key says nothing about another.
export function unguarded() {
  return page[PAGINATION].total;
}

export function otherKeyNotNarrowed() {
  if (page[PAGINATION]) {
    return page[OTHER].total;
  }
  return 0;
}
