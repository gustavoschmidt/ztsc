/// <reference path="./decls.d.ts" />
import wrap from "untypedlib";

const inst = wrap(1);

// `alpha` is inherited from the interface the ambient block imported.
const a: string = inst.reduce({ max: 1, alpha: true });
// ... and an imported type used directly resolves too.
const b: string = inst.engine().run({ alpha: false });

// Negative controls.
const bad: string = inst.reduce({ max: 1, nope: true });
const missing = inst.engine().absent();

export { a, b, bad, missing };
