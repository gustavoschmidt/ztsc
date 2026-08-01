// A package that publishes an `exports` map is a closed set of entry points.
// `widgetlib/internal` IS a file on disk (legacy probing would resolve
// node_modules/widgetlib/internal.d.ts), but it is NOT named by the `exports`
// map, so bundler/Node16 resolution refuses it — TS2307 on line 12. Symbol
// liveness and the diagnostic are decoupled: dangling the specifier is not
// crash-safe under parallel resolution, so the resolver still routes the
// blocked subpath to a stable opaque `any` module (nothing dangles), and the
// linker reports TS2307 at the specifier for that stand-in anyway. So `secret`
// is `any` — tsc's observable type at such an import too — and the `.` entry
// still resolves concretely to `number`.
import { widget } from "widgetlib";
import { secret } from "widgetlib/internal";
const w: number = widget;
const bad: string = widget; // TS2322 — widget is number (the `.` entry)
const s1: string = secret; // ok — secret degraded to `any`
const s2: number = secret; // ok — `any` (would be TS2322 if it resolved to string)
