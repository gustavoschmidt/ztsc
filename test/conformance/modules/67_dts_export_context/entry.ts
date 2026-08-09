import { type Hidden, type HiddenShape, pick, shape } from "./barrel";
import { type Helper } from "./helper";

const tone: Hidden = "dark";
const s: HiddenShape = { tone };
const h: Helper = { id: 1 };
const got: Hidden = pick(h);
const also: Hidden = shape.tone;

// A non-declaration file gets no export context: `Local` stays private, so
// this is the ordinary TS2459 ("declares it locally, but it is not exported").
import { Local } from "./impl";
const bad: Local = 1;

export { tone, s, got, also, bad };
