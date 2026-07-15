# react_accept_real — the real-`@types/react` acceptance gate

A small real `.tsx` app (`src/`) checked against the **real published
`@types/react` 18.3.11** (plus its deps `csstype` 3.1.3 and
`@types/prop-types` 15.7.13), asserting ztsc's user-code diagnostics match
the pinned **tsgo 7.0.2** oracle byte-for-byte on `TS<code> <file> <line>`.

The committed conformance cases (`test/conformance/jsx/*`) pin the JSX
semantics against hand-authored `JSX` namespaces; this gate proves the
ecosystem path — the checker resolving the global `JSX` namespace merged out
of `@types/react`'s `declare global` block, `IntrinsicAttributes`
(`key`), `ElementChildrenAttribute` (children), intrinsic `div`/`span`
props from `DetailedHTMLProps` intersections, spread attributes, and the
`export = React` / `import * as React` module shape.

The fixture plants ten mistakes spanning: wrong attribute type (TS2322),
missing required prop (TS2741), excess prop on component and intrinsic
(TS2322), spread missing a prop (TS2741), non-object spread (TS2698 +
TS2322), literal-overwritten-by-spread (TS2783), and missing `children`
(TS2741) — each byte-matched against tsgo on code+line. Correct usage
(components, class component, spread forwarding, `key`, children, `style`
via csstype) must stay clean.

The corpus is gitignored, so this is a scripted gate, not a `zig build
test` case:

```sh
bench/fetch_real.sh           # once, to vendor @types/react + deps
zig build                     # or `zig build bench` (preferred binary)
test/react_accept_real/run.sh
```

Known divergences (documented leniency, not gate failures — the fixture
avoids these shapes): prop *type* mismatches that arrive **inside** a spread
object are not reported (tsc: TS2322 at the tag); class-component prop
mistakes report refined codes (TS2741/TS2322) where tsgo's real-React path
reports TS2769; children *value* types are not checked (tsc: TS2745/2746).
