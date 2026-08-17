// `typeof <ref>.k === "…"` is a discriminant guard on `<ref>`, exactly as
// `<ref>.k === <literal>` is: tsc's `narrowTypeByTypeof` falls through to
// `getDiscriminantPropertyAccess` whenever the operand is a property access on
// the reference rather than the reference itself.
declare const a: { error: { prop: string }; result: undefined } | { error: undefined; result: { prop: number } };

function bothBranches(): number {
  if (typeof a.error === "undefined") {
    return a.result.prop;
  } else {
    return a.error.prop.length;
  }
}

// The equality spelling of the same guard, which already worked — kept so the
// two stay in step.
function equalityForm(): number {
  if (a.error === undefined) {
    return a.result.prop;
  }
  return a.error.prop.length;
}

// A non-discriminant property is left alone: `tag` is uniform, so no
// constituent is ruled out and `v.payload` keeps the whole union.
declare const v: { tag: string; payload: string } | { tag: string; payload: number };
function notADiscriminant(): string {
  if (typeof v.tag === "string") {
    return v.payload;
  }
  return "";
}

export { bothBranches, equalityForm, notADiscriminant };
