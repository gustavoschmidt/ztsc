// A package that publishes an `exports` map is a closed set of entry points:
// `widgetlib/internal` is a real file on disk but is NOT named by `exports`,
// so bundler/Node16 resolution (and ztsc) must NOT resolve it — the import is
// blocked (TS2307) and `secret` degrades to `any`. The `.` entry still works.
import { widget } from "widgetlib";
import { secret } from "widgetlib/internal";
const w: number = widget;
const bad: string = widget;
const s: string = secret;
