/// <reference path="./ambient.d.ts" />
import { applyToPoint, compose, identity, Matrix, translate } from "tmat";

const m: Matrix = compose(identity(), translate(1, 2));
const p: [number, number] = applyToPoint(m, [0, 0]);
const q: number = p[0];

// Negative controls: the starred declarations keep their real signatures, and a
// name no block contributes is still missing.
const bad1: number = identity();
const bad2 = translate("x");

export { m, p, q, bad1, bad2 };
