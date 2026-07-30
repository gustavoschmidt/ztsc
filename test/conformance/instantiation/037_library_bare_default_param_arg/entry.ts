import { combine, configure, type Red, type Slice } from "./lib";

type LoadingState = { loading: boolean };
type UserState = { user: string };

declare const loadingSlice: Slice<LoadingState, "loading">;
declare const userSlice: Slice<UserState, "user">;

// `Slice<LoadingState>["reducer"]` must be `Red<LoadingState, Act, LoadingState>`
// — the default `P = S` bound to the supplied argument, with no free `S` left.
const one: Red<LoadingState> = loadingSlice.reducer; // ok — reflexive

const root = combine({
  loading: loadingSlice.reducer,
  user: userSlice.reducer,
});

// The `M[keyof M] extends Red<…> | undefined` check is only decidable once the
// map's members are ground; then `root` is a real reducer over the combined
// state and both `configure` branches accept it.
const state = configure({ reducer: root });
const ok: { loading: LoadingState; user: UserState } = state; // ok

// Negatives — the reduced type is still checked, not widened to `any`.
const bad1: { loading: LoadingState; user: number } = state; // TS2322
const bad2: Red<UserState> = loadingSlice.reducer; // TS2322

export { one, ok, bad1, bad2 };
