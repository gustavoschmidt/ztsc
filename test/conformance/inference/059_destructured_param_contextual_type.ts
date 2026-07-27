// The bindings of a DESTRUCTURED parameter must get their types from the
// parameter type the contextual signature supplies. A named parameter's symbol
// is pinned to that type when the signature is built; a pattern parameter names
// no symbol, so its bindings had no pinned type and fell back to re-deriving
// the parameter from the declaration alone — with no contextual signature to
// read, i.e. `any`. Every read of such a binding was then unchecked, and the
// `any` spread outward through inference.
type El = { fillStyle: "hachure" | "solid" };
type AppState = { currentItemFillStyle: "hachure" | "solid" };
type PanelProps = { els: readonly El[]; st: AppState; n?: number };

declare function register(a: { Panel: (p: PanelProps) => string }): void;

// The bindings are typed, so misuse is caught.
register({
  Panel: ({ els, st }) => {
    const bad: number = st;
    const bad2: number = els;
    const bad3 = st.nosuchprop;
    return "" + bad + bad2 + bad3;
  },
});

// An optional property binds `| undefined`, and a default strips it — the same
// walk the non-contextual path uses, so nothing about those rules changes.
register({
  Panel: ({ n, st }) => {
    const stillOptional: number = n;
    return st.currentItemFillStyle;
  },
});
register({
  Panel: ({ n = 1 }) => {
    const defaulted: number = n;
    return String(defaulted);
  },
});

// Nested and renamed bindings.
declare function reg2(a: { P: (p: { o: { deep: string }; x: number }) => void }): void;
reg2({
  P: ({ o: { deep }, x: renamed }) => {
    const bad4: number = deep;
    const bad5: string = renamed;
  },
});

// The consequence this came from: a binding typed `any` infers a generic call's
// type parameter as `any`, and `any` absorbs the union parameter beside it, so
// the arrow written for that parameter loses its contextual signature.
type Primitive = number | string | boolean | null | undefined;
declare const getFormValue: <T extends Primitive>(
  elements: readonly El[],
  appState: AppState,
  getAttribute: (element: El) => T,
  defaultValue: T | ((isSomeElementSelected: boolean) => T),
) => T;

register({
  Panel: ({ els, st }) => {
    const v = getFormValue(
      els,
      st,
      (element) => element.fillStyle,
      // `hasSelection` is `boolean` from the union's function constituent.
      (hasSelection) => (hasSelection ? null : st.currentItemFillStyle),
    );
    return v ?? "";
  },
});

// Control: an ANNOTATED destructured parameter was always typed, and stays so.
export const annotated = ({ st }: PanelProps) => {
  const bad6: number = st;
  return bad6;
};
