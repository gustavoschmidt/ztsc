// Overload applicability includes the FRESHNESS/excess-property check. tsc runs
// the excess-property test inside the assignability relation, and for a union
// target it runs it once per constituent — so `{ leading: false }` is not
// applicable to the first overload here: the `& { leading: true }` arm rejects
// `false`, and the `Omit<…, "leading">` arm does not know `leading` at all.
// Selecting that overload anyway made the call type "LEADING" and then filed a
// TS2345 on the argument — the very error moving to the next overload avoids.
interface ThrottleSettings {
  leading?: boolean | undefined;
  trailing?: boolean | undefined;
}
type ThrottleSettingsLeading =
  | (ThrottleSettings & { leading: true })
  | Omit<ThrottleSettings, "leading">;

declare function throttle(wait: number, options?: ThrottleSettingsLeading): "LEADING";
declare function throttle(wait: number, options?: ThrottleSettings): "PLAIN";

// `leading: false` is excess for the `Omit` arm and wrong for the `&` arm, so
// the LEADING overload is inapplicable and the PLAIN one wins.
const a: "PLAIN" = throttle(100, { leading: false });
// `leading: true` keeps its literal type under the contextual union, so the
// first overload still applies.
const b: "LEADING" = throttle(100, { leading: true });
// No properties at all: applicable to the `Omit` arm, first overload again.
const c: "LEADING" = throttle(100, {});
const d: "LEADING" = throttle(100, { leading: true, trailing: false });

// A non-union parameter: an excess property makes the first overload
// inapplicable rather than producing TS2353 on the winning one.
declare function pick(o: { a: number }): "A";
declare function pick(o: { a: number; b: number }): "AB";
const e: "AB" = pick({ a: 1, b: 2 });

// Negative: when NO overload accepts the literal, the excess property is still
// reported (through the last candidate) rather than silently swallowed.
declare function only(o: { a: number }): void;
declare function only(o: { a: number; c: number }): void;
only({ a: 1, b: 2 });

export { a, b, c, d, e };
