import * as L from "nslib";
import "nslib-plugin";

// Ambient .d.ts namespace members are visible without an `export` keyword.
const a: number = L.control.scale();
const b: number = L.Util.stamp(null);
// Cross-package value/namespace augmentation reaches the namespace object.
const c: number = L.control.sideBySide();
const d: string = L.drawLocal.title;

// Negative controls: genuinely-absent members still error.
L.control.absent();
L.missingExport;
