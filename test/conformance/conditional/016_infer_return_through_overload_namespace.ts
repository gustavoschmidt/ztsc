// A callable that is ALSO a namespace (like node's `setTimeout` merged with
// `namespace setTimeout`) materializes as `overloads & namespaceObject`.
// `ReturnType` / any `(...args) => infer R` pattern must still read the call
// signature through that intersection instead of collapsing to `unknown`.
interface Timeout {
  _tag: 'timeout';
}

declare function makeTimer(cb: () => void, ms?: number): Timeout;
declare function makeTimer(cb: (x: void) => void, ms?: number): Timeout;
declare namespace makeTimer {
  const label: string;
}

type R = ReturnType<typeof makeTimer>;

// R is `Timeout`, so assigning it to `string` is TS2322 (proving R is a real
// type, not `unknown` — `unknown` would report the same line but the fixture
// pins the mechanism: the callable was found through the fn+namespace merge).
const bad: string = null as any as R;

// A `Timeout` value flows where `R` is expected: consistent, no error.
const ok: R = makeTimer(() => {});
