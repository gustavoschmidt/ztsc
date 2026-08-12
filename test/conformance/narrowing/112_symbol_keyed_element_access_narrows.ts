// An element access keyed by a `unique symbol` is a tracked reference exactly
// like `a[0]` or `a.p`, so a guard on it narrows the reads of the same access.
// outline's `MembershipPreview` guards `page[PAGINATION_SYMBOL]` this way.

declare const SYM: unique symbol;
declare const page: { [SYM]?: { total: number } };

export function truthinessNarrows() {
  if (page[SYM]) {
    return page[SYM].total;
  }
  return 0;
}

declare const SYM2: unique symbol;
declare const page2: { [SYM2]: { total: number } | undefined };

export function equalityNarrows() {
  if (page2[SYM2] !== undefined) {
    return page2[SYM2].total;
  }
  return 0;
}

declare const SYMI: unique symbol;
interface Paged {
  [SYMI]?: { total: number };
}
declare const paged: Paged;

export function throughAnInterface() {
  if (paged[SYMI]) {
    return paged[SYMI].total;
  }
  return 0;
}

// Negative control: an unguarded read is still optional, and a guard on ONE
// symbol key says nothing about another.
declare const other: { [SYM]?: { total: number }; [SYM2]?: { total: number } };

export function unguardedStaysOptional() {
  return other[SYM].total; // TS18048
}

export function otherKeyNotNarrowed() {
  if (other[SYM]) {
    return other[SYM2].total; // TS18048
  }
  return 0;
}
