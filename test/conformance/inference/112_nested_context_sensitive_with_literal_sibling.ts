// A context-sensitive object-literal argument whose sensitivity lives ONE LEVEL
// DOWN, beside a sibling property that asks for a literal-keeping contextual
// type. This is redux-toolkit's `createSlice({ name, initialState, reducers })`:
// `name: Name` (`Name extends string`) wants its `"thing"` kept, while
// `reducers` is a bag of un-annotated case reducers.
//
// Two things were missing. `isContextSensitive` did not RECURSE into a nested
// object literal, so the argument was judged insensitive; and a literal-keeping
// contextual type suppressed the two-pass split outright. The argument was
// therefore read exactly once, with `State` still a free variable, so `CR` was
// inferred as `{ … (state: State) => void … }`, failed its own
// `CR extends Con<State>` constraint, and was clamped to that constraint —
// whose `keyof` is `string`, so `{ [T in keyof CR]: … }` came out `{}`.
//
// The split is safe to widen only for a NESTED-only sensitivity: an
// un-annotated callback at the literal's own top level is named directly by a
// property of the parameter type, so the single contextual read types it and
// is the better reading. And pass one's candidates, like its fallbacks, are
// instantiated in declaration order before pass two sees them, which is what
// closes `State`.

type Con<State> = Record<string, (s: State) => void>;
type Validated<S, ACR extends Con<S>> = ACR & { [T in keyof ACR]: {} };

declare function mk<State, CR extends Con<State>, Name extends string>(o: {
  name: Name;
  initialState: State;
  reducers: Validated<State, CR>;
}): { actions: { [T in keyof CR]: CR[T] }; nm: Name };

type St = { open: boolean };
declare const initialState: St;

const s = mk({
  name: "thing",
  initialState,
  reducers: {
    close(state) {
      state.open = false;
    },
  },
});

// The written keys survive, and the case reducer's parameter is the state.
const ok: { close: (state: St) => void } = s.actions;

// The sibling literal is still kept: `Name` is `"thing"`, not `string`.
const nm: "thing" = s.nm;

// NEGATIVE — the reduced types are still checked, not widened to `any`.
const bad1: { close: (state: St) => void; other: () => void } = s.actions; // TS2741
const bad2: "other" = s.nm; // TS2322

// Regression: a TOP-LEVEL un-annotated callback keeps the two-pass reading it
// already had — the widened gate must not disturb it.
declare function top<T>(o: { v: T; onChange: (value: T) => void }): { v: T };
const t = top({
  v: "x",
  onChange: (value) => {
    const str: string = value;
    void str;
  },
});
const tv: string = t.v;

export { ok, nm, bad1, bad2, tv };
