// A global function declared by the default library and again by a module's
// `declare global` block merges into ONE overload set carrying both sets of
// signatures — the shape `setTimeout`/`clearTimeout`/`fetch` have in any
// project that pulls in @types/node next to lib.dom. Keeping only one
// contributor's signatures made the other's calls fail and made a call that
// matches NEITHER report a bare argument error instead of TS2769.
import "./aug";

declare const t: Timer;

// RESOLUTION order: the augmentation's group is tried first, so this is a
// `Timer`, not lib.dom's `number`.
const a: number = setTimeout(() => {}, 1);

// ...and lib.dom's signature is still reachable — the augmentation's `cb`
// rejects a string handler, lib.dom's `TimerHandler` accepts it.
const b: number = setTimeout("code", 1);

// Neither signature accepts a number handler: an overload SET reports
// TS2769, a lone signature could only ever report the argument.
setTimeout(123 as unknown as number, 1);

// Both contributors' `clearTimeout` are callable.
clearTimeout(t);
clearTimeout(1);

// DECLARATION order, which is the other one: `Parameters` aligns from the
// END, so it is the augmentation's signature, not lib.dom's.
declare function want(p: Parameters<typeof clearTimeout>): void;
want([t]);
want([1]);

export { a, b };
