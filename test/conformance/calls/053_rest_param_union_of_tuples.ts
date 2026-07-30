// A rest parameter typed by a UNION OF TUPLES is one parameter list chosen as
// a WHOLE ARM — the shape i18next's `TFunction` takes so a translation call
// can pass options, or a default value, or both. There is no per-position type
// that describes it: position 1 below would have to union the options bag with
// the default string, which relates to neither a `(key, options?)` nor a
// `(key, defaultValue, options?)` target.
//
// tsc's `compareSignaturesRelated` sees a `getNonArrayRestType`, stops the
// pairwise walk at that position and relates the OTHER side's remaining
// parameters, packed into one tuple (`getRestTypeAtPosition`), against the
// union — so exactly one arm has to accept the whole list.
interface Opts {
  ns: string;
  count?: number;
}

declare function t(
  ...args: [key: string, options?: Opts] | [key: string, defaultValue: string, options?: Opts]
): string;

// RELATION — the target's parameter list satisfies the first arm.
export const a1: (key: string, options?: Opts) => string = t;
// RELATION — and the second.
export const a2: (key: string, defaultValue: string, options?: Opts) => string = t;

// RELATION, NEGATIVE — no arm takes a number key.
export const a3: (key: number) => string = t;
// RELATION, NEGATIVE — the options slot is not a number in either arm.
export const a4: (key: string, options?: number) => string = t;
// RELATION, NEGATIVE — an unbounded target rest reaches past every arm.
export const a5: (key: string, ...rest: Opts[]) => string = t;

// RELATION, symmetric — a union-of-tuples rest in the TARGET makes the
// SOURCE's parameter list the tuple that has to satisfy an arm. `narrow`
// requires its options bag, which no arm guarantees.
declare function narrow(key: string, options: Opts): string;
export const b1: (
  ...args: [key: string, options?: Opts] | [key: string, defaultValue: string, options?: Opts]
) => string = narrow;

// CALLS — each arm, at each of its arities.
export const c1 = t("k");
export const c2 = t("k", { ns: "x" });
export const c3 = t("k", "default");
export const c4 = t("k", "default", { ns: "x" });

// The options slot is OPTIONAL in the first arm, so an `Opts | undefined` fits
// it — the position admits `undefined` because one arm says the argument may
// be left out.
declare const maybe: Opts | undefined;
export const c5 = t("k", maybe);

// CALL, NEGATIVE — neither arm has a number in the second slot.
export const c6 = t("k", 42);

// CALL, NEGATIVE — the list as a whole still has to satisfy one arm: an
// options bag in the *defaultValue* slot mixes them.
export const c7 = t("k", { ns: "x" }, { ns: "y" });
