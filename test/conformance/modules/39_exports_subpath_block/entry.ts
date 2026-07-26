// A package that publishes an `exports` map is a closed set of entry points.
// `widgetlib/internal` IS a file on disk (legacy probing would resolve
// node_modules/widgetlib/internal.d.ts), but it is NOT named by the `exports`
// map, so bundler/Node16 resolution refuses it. Rather than dangle the
// specifier (unresolved — which is not crash-safe under parallel resolution),
// ztsc routes such an exports-blocked subpath to an opaque `any` module,
// under-reporting the TS2307 tsc emits for an app-level import here (the
// snapshot keeps the oracle's TS2307; the divergence is registered in
// `test/conformance/DEFERRED`). So
// `secret` is `any`; the `.` entry still resolves concretely to `number`.
import { widget } from "widgetlib";
import { secret } from "widgetlib/internal";
const w: number = widget;
const bad: string = widget; // TS2322 — widget is number (the `.` entry)
const s1: string = secret; // ok — secret degraded to `any`
const s2: number = secret; // ok — `any` (would be TS2322 if it resolved to string)
