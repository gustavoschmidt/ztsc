// Optional-chain-guard base narrowing: a truthy optional chain, or a
// `typeof <chain>` that the branch forces to be non-"undefined", implies the
// chain's receivers did not short-circuit, so those receivers narrow to
// non-null (tsc's narrowTypeByTruthiness / narrowTypeByTypeof optional-chain-
// containment rules). Only the RECEIVER references (chain root + single-level
// members) narrow — arbitrary-depth paths like `lead.attrs.name` are not
// tracked (RefKey is depth-1) and are deliberately not asserted here.
// Negative controls (falsy/else branch, `=== "undefined"` true branch,
// `=== "string"` else branch) must NOT narrow — those lines still error.
// Renamed minimized repros of dogfood-project patterns.
interface Flow {
  id: string;
}
interface Detail {
  flow: Flow;
}
interface Attrs {
  name?: string;
}
interface Lead {
  id: string;
  attrs: Attrs;
}
declare function useD(x: Detail): void;
declare function useL(x: Lead): void;
declare function useObj(x: { data: object }): void;
declare const detail: Detail | null;
declare const lead: Lead | undefined;

// Shape 1 (truthiness): negated chain early-return narrows the root receiver.
function s1_earlyReturn() {
  if (!detail?.flow.id) return;
  useD(detail); // OK: detail narrowed non-null
}

// Shape 1b (truthiness): truthy chain in the if-body narrows the root.
function s1b_ifBody() {
  if (detail?.flow.id) useD(detail); // OK
}

// Shape 2 (typeof): `=== "string"` (non-"undefined") narrows the root receiver.
function s2_typeofString() {
  if (typeof lead?.attrs?.name === "string") useL(lead); // OK
}

// Shape 2b (typeof): `!== "undefined"` narrows the root receiver.
function s2b_neqUndef() {
  if (typeof lead?.id !== "undefined") useL(lead); // OK
}

// Shape 3 (typeof in &&): first conjunct narrows the receiver for later
// conjuncts and the body.
function s3_andChain(err: { response?: { data: object } }) {
  if (typeof err.response?.data === "object" && err.response?.data !== null) {
    useObj(err.response); // OK: err.response narrowed non-undefined
  }
}

// Negative control: else branch of a truthy chain does NOT narrow.
function neg_truthy_else() {
  if (detail?.flow.id) {
  } else useD(detail); // error: detail possibly null
}

// Negative control: `typeof chain === "undefined"` true branch does NOT narrow
// (the chain may have short-circuited to undefined).
function neg_typeof_eq_undef() {
  if (typeof lead?.id === "undefined") useL(lead); // error: lead possibly undefined
}

// Negative control: `typeof chain === "string"` else branch does NOT narrow.
function neg_typeof_string_else() {
  if (typeof lead?.id === "string") {
  } else useL(lead); // error: lead possibly undefined
}
