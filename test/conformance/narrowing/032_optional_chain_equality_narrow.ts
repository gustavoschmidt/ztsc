// Optional-chain containment narrowing on equality/comparison guards
// (tsc's narrowTypeByOptionalChainContainment). `a?.m() === <value>` narrows
// the chain RECEIVER `a` to non-null in the branch where the comparison can
// only hold for a non-short-circuited chain. Negative controls (=== undefined,
// == null, comparand typed with undefined, any/unknown comparand) must NOT
// narrow — those lines still error. Renamed minimized repro of a
// testing-library `Element | null` pattern from the dogfood project.
interface El {
  getAttribute(n: string): string | null;
  b: { c: string } | null;
}
declare function use(x: El): void;
declare function useC(x: { c: string }): void;
declare const el: El | null;
declare const maybe: string | undefined;
declare const anyv: any;
declare const unk: unknown;

// Positive: receiver narrows to non-null (no error).
function pos_lit() {
  if (el?.getAttribute("x") === "y") use(el);
}
function pos_neq_undef() {
  if (el?.getAttribute("x") !== undefined) use(el);
}
function pos_neq_null() {
  if (el?.getAttribute("x") != null) use(el);
}
function pos_eq_null() {
  if (el?.getAttribute("x") === null) use(el);
}
function pos_eq_undef_else() {
  if (el?.getAttribute("x") === undefined) {
  } else use(el);
}
function pos_deep_head() {
  if (el?.b?.c === "y") {
    use(el);
    useC(el.b);
  }
}

// Negative controls: receiver must NOT narrow (still `El | null`) -> error.
function neg_eq_undef() {
  if (el?.getAttribute("x") === undefined) use(el);
}
function neg_eq_null_loose() {
  if (el?.getAttribute("x") == null) use(el);
}
function neg_eq_maybe() {
  if (el?.getAttribute("x") === maybe) use(el);
}
function neg_eq_any() {
  if (el?.getAttribute("x") === anyv) use(el);
}
function neg_eq_unk() {
  if (el?.getAttribute("x") === unk) use(el);
}
function neg_lit_else() {
  if (el?.getAttribute("x") === "y") {
  } else use(el);
}
