import { base, Extra, Alias, Wrap } from "newlib";
import "newlib-plugin";

// Names an augmentation introduces are exports of the augmented module.
const a: boolean = (null as any as Extra).deep;
const c: Alias = { deep: true };
// ... including across packages, and through a cross-block reference.
const b: number = base.fromPlugin;
const w: Wrap = { inner: { deep: false } };

// Negative controls.
const bad: string = (null as any as Extra).deep;
const nope = (null as any as Wrap).missing;

export { a, b, c, w, bad, nope };
