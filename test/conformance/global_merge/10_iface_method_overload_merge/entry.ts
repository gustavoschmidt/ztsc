import "./a";
import "./b";
declare const w: Widget;
// Both overloads survive the cross-file interface merge (without the merge,
// the object-arg call would fail overload resolution):
const r1: string = w.render();
const r2: string = w.render({ color: "red" });
// Negative control: the merged overload returns `string`, so binding it to
// `number` is TS2322 — proving the overload resolved AND kept its return.
const r3: number = w.render({ color: "red" });
