import { origin, needsString } from "./decls";

// .d.ts-declared types still flow into .ts checking: correct uses are clean.
const px: number = origin.x;
needsString("ok");
void px;

// A .ts error that involves a .d.ts-declared signature is STILL reported
// (skipLibCheck suppresses diagnostics located in .d.ts, not in .ts): TS2345.
needsString(123);
