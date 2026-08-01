// An intersection SOURCE must still reach the deferred-target rules. The
// intersection-source arm ends in `return false` for every non-object target,
// so ordering it first made the indexed-access-target and conditional-target
// rules unreachable from a branded scalar (`number & { _brand }`) — the
// canonical way such a type is written through a `T["k"]` annotation.
type Radians = number & { _brand: "rad" };
type Base = { angle: Radians; label: string };

export const write = <T extends Base>(e: T) => {
  // `T["angle"]`'s base constraint is `Radians`; the branded source relates.
  const ok: T["angle"] = e.angle;
  // A plain number is NOT a `Radians`, so the rule still rejects.
  const bad: T["angle"] = 1;
  // The non-intersection member of the same shape was already accepted.
  const okStr: T["label"] = e.label;
  const badStr: T["label"] = 1;
  return [ok, bad, okStr, badStr];
};

// Deferred conditional target (`T` is free, so it does not resolve), same
// intersection source. Both rows are rejected: an INLINE distributive
// conditional annotating a `const` inside the function body does not get the
// satisfy-both-branches leniency (tsc treats it as distribution dependent —
// a block separates it from `T`'s declaration), so even a `Radians`/`Radians`
// conditional rejects here. conditional/035 pins the full extent.
export const cond = <T extends Base>(e: T) => {
  const okCond: T extends 0 ? Radians : Radians = e.angle;
  const badCond: T extends 0 ? string : string = e.angle;
  return [okCond, badCond];
};

// A non-generic object target still takes the merged-members path.
type Named = { _brand: "rad" };
declare const rad: Radians;
export const okObj: Named = rad;
export const badObj: { _brand: "deg" } = rad;
