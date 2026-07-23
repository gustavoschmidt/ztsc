// Constant-index element access as a discriminable reference. The
// flow-narrowing reference key admits a constant `[i]` link in a member path
// (`data.arr[0].prop`), tracked up to depth 3 alongside dotted members. A guard
// on such a path narrows subsequent reads of the SAME constant index; a
// DIFFERENT index does not inherit the narrowing; and writing any prefix —
// including through the index — invalidates the subtree. Constant indices only:
// a variable index is not a constant reference and is left untracked (sound
// under-narrowing). Minimized repro of the dogfood project's
// `filterRows.rowsProfile[0].toValue` truthiness guard.

interface Detail {
  label: string;
}
interface Row {
  enable?: boolean;
  detail?: Detail;
}
interface Rows {
  rowsProfile: Row[];
}

// POSITIVE (must NOT error) --------------------------------------------------
// Truthiness guard on a constant-index path narrows the same read (depth 3:
// rowsProfile, [0], detail).
function p_index_truthy(r: Rows): string {
  if (r.rowsProfile[0].enable && r.rowsProfile[0].detail) {
    return r.rowsProfile[0].detail.label; // OK: detail narrowed to Detail
  }
  return "";
}

// Optional-chain containment through a constant index: a truthy
// `r.rowsProfile?.[0]?.detail` implies the receiver did not short-circuit.
function p_index_optchain(r: Rows): string {
  if (r.rowsProfile?.[0]?.detail) {
    return r.rowsProfile[0].detail.label; // OK
  }
  return "";
}

// NEGATIVE CONTROLS (MUST error) ---------------------------------------------
// A DIFFERENT index does not inherit the narrowing: guarding [0] says nothing
// about [1].
function n_other_index(r: Rows): string {
  if (r.rowsProfile[0].detail) {
    return r.rowsProfile[1].detail.label; // error TS2532: [1].detail undefined
  }
  return "";
}

// Writing through the index prefix invalidates the subtree.
function n_prefix_write(r: Rows, fresh: Row): string {
  if (r.rowsProfile[0].detail) {
    r.rowsProfile[0] = fresh; // invalidates r.rowsProfile[0].detail narrowing
    return r.rowsProfile[0].detail.label; // error TS2532: re-widened
  }
  return "";
}
