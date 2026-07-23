// A class may `extend` a *value* whose type carries construct signatures
// (the mixin-base pattern: `declare const Base: { new (input): R }`, as
// emitted by the AWS-SDK Smithy `class XCommand extends XCommand_base`).
// The derived class inherits both the construct signature (so `new
// Derived(args)` type-checks its argument) and the signature's return type
// as its base instance (so inherited members resolve).
declare const Base: {
  new (input: { x: number }): { y: string; ping(): number };
  getMeta(): string;
};
class Derived extends Base {
  extra = 5;
}
const d = new Derived({ x: 1 });
const okY: string = d.y;
const okPing: number = d.ping();
const okExtra: number = d.extra;

// Negative controls:
const badY: number = d.y; // TS2322 string -> number
new Derived(); // TS2554 missing the required input argument
d.missing(); // TS2339 no such member
