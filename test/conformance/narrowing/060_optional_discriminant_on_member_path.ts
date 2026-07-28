// An OPTIONAL discriminant read narrows, and the depth of the reference it is
// read from does not matter. tsc's `getDiscriminantPropertyAccess` accepts
// `x?.kind === lit` and `s.slot?.kind === lit` alike: the union being filtered
// is the reference's own type either way.
//
// ztsc accepted the optional form only for a *root symbol* reference, on the
// theory that `m?.k` on a tracked member path is the optional-chain
// containment pattern rather than a discriminant read. It is both, and the
// containment half was already applied on top of the discriminant filter — so
// the depth test only lost the filter. Every `appState.openDialog?.name ===
// …` in a real application went unnarrowed.

type Dialog =
  | { name: "commandPalette" }
  | { name: "elementLinkSelector"; sourceElementId: string }
  | { name: "help" | "imageExport" | "jsonExport" }
  | { name: "ttd"; tab: string };

type State = { openDialog: Dialog | null };

// Member-path reference, negative sense: the early return leaves the "ttd"
// member, `null` included in what was filtered out.
export function guarded(s: State) {
  if (s.openDialog?.name !== "ttd") {
    return null;
  }
  return s.openDialog.tab;
}

// Positive sense, and the ternary spelling of it.
export function positive(s: State) {
  if (s.openDialog?.name === "ttd") {
    return s.openDialog.tab;
  }
  return null;
}

export function ternary(s: State) {
  return s.openDialog?.name === "ttd" ? s.openDialog.tab : null;
}

// The root-symbol form, which already worked — kept as the control that says
// the two depths now agree.
export function rootRef(d: Dialog | null) {
  if (d?.name !== "ttd") {
    return null;
  }
  return d.tab;
}

// And the hand-written equivalent, which also already worked.
export function explicitNullCheck(s: State) {
  if (s.openDialog === null || s.openDialog.name !== "ttd") {
    return null;
  }
  return s.openDialog.tab;
}

// The negative branch keeps `null`: `?.name !== "ttd"` holds when the receiver
// short-circuited, so nothing about nullishness follows from it.
export function negativeBranchKeepsNull(s: State) {
  if (s.openDialog?.name === "ttd") {
    return "";
  }
  return s.openDialog.name;
}

// A discriminant the union does not agree on is still a discriminant read; the
// filter just keeps the members that can have it.
export function partialDiscriminant(s: State) {
  if (s.openDialog?.name === "elementLinkSelector") {
    return s.openDialog.sourceElementId;
  }
  return null;
}
