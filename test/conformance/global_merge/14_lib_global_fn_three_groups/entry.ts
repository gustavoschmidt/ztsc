// THREE declaration groups for one global function — lib.dom plus two
// `declare global` augmentations, the shape social-app's `setTimeout` has
// (lib.dom + @types/node + react-native). Overload RESOLUTION visits the
// groups back-to-front, so the LAST one wins; `ReturnType` aligns from the end
// of DECLARATION order, so it names the same last group. The two paths must
// agree. A single lib/non-lib rotation instead puts the FIRST augmentation in
// front, and then a slot typed by `ReturnType<typeof setTimeout>` cannot hold
// the result of calling it.
import "./aug1";
import "./aug2";

// The whole point: the call and `ReturnType` pick the SAME signature.
const slot: ReturnType<typeof setTimeout> = setTimeout(() => {}, 1);

// Both paths name the last group (`TimerB`), not `TimerA` and not `number`.
const fromCall: null = setTimeout(() => {}, 1);
declare const r: ReturnType<typeof setTimeout>;
const fromReturnType: null = r;

// lib.dom's signature is still reachable — only it accepts a string handler.
const b: number = setTimeout("code", 1);

// And no group accepts a number handler, so the set still reports TS2769.
setTimeout(123 as unknown as number, 1);

export { slot, fromCall, fromReturnType, b };
