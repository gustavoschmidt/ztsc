// tsc's `fillMissingTypeArguments` instantiates each omitted type argument's
// DEFAULT through the mapper built from the arguments so far, so
// `NavProp<T>` is `NavProp<T, Keyof<T>, string | undefined, NavState<T>, {}>`
// -- every occurrence of the alias's own `PL` closed by `T`.
//
// ztsc keeps a lenient branch that leaves a library default unsubstituted
// (threading a concrete argument through a deeply recursive `.d.ts` term was
// an OOM, and through a still-deferred reduction an unmasking). A default
// that resolves to a bare NAMED REFERENCE is exempt: instantiating a `.ref`
// rewrites its argument list and expands nothing, so neither hazard applies.
// Without the exemption `S = NavState<PL>` kept the alias's own `PL`, the
// signature's later instantiation at `T = Params` could never close it, and
// the parameter was spelled over a free type parameter no argument can meet.

import { root, type NavProp, type NavState } from './nav';

type Params = { Home: undefined; Search: { q: string } };

declare const np: NavProp<Params>;

// The generic call and the written annotation must agree.
const a = root<Params>(np);
const b = root(np);

// The `routeNames` of the state the callback receives is closed over `Params`.
a.dispatch((state) => {
  const names: ('Home' | 'Search')[] = state.routeNames;
  const bad: 'Home'[] = state.routeNames; // TS2322
  return [names, bad];
});

declare const wrongState: NavState<{ Other: undefined }>;
const c: NavState<Params> = wrongState; // TS2322

export { a, b, c };
