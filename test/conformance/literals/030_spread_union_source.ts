// Spreading a UNION-typed value into an object literal.
//
// `gatherSpreadProps` had arms for an object and an intersection source but
// none for a union, so `{ ...(tool || { type: "selection" }), extra }`
// contributed NOTHING — the spread's properties vanished and the literal failed
// every target that requires them. tsc's `getSpreadType` distributes and yields
// a union of spread results; when that distribution does not apply (see
// literals/033) the constituents are FOLDED into one object instead: a property
// every member declares keeps the union of its types, one some member lacks
// becomes optional.

type Tool = "selection" | "rectangle" | "eraser";
type Full = { type: Tool; locked: boolean };
type Short = { type: "selection" };

declare const u: Full | Short;

// POSITIVE (must NOT error) --------------------------------------------------

// `type` is declared by both members, so it survives as a required property.
declare function wantType(v: { type: Tool; extra: null }): void;
export const p1 = wantType({ ...u, extra: null });

// A property only one member declares comes through optional, which satisfies
// an optional target.
declare function wantOpt(v: { type: Tool; locked?: boolean }): void;
export const p2 = wantOpt({ ...u });

// `null` / `undefined` members of the union spread nothing and do not stop the
// object members from folding.
declare const un: Full | Short | null | undefined;
export const p3 = wantType({ ...un, extra: null });

// A later explicit property still wins over the spread.
export const p4 = wantType({ ...u, type: "eraser", extra: null });

// Regression: a plain object source and an intersection source are unchanged.
declare const o: Full;
declare const i: { type: Tool } & { locked: boolean };
export const p5 = wantType({ ...o, extra: null });
export const p6 = wantType({ ...i, extra: null });

// Regression: an explicit required property is not made optional by a later
// spread that declares it optionally.
declare const partial: { type?: Tool };
declare function wantReq(v: { type: Tool }): void;
export const p7 = wantReq({ type: "eraser", ...partial });

// NEGATIVE (must error) ------------------------------------------------------

// A property only one member declares is OPTIONAL in the fold, so it does not
// satisfy a required target.
declare function wantLocked(v: { type: Tool; locked: boolean }): void;
export const n1 = wantLocked({ ...u }); // TS2345

// A property no member declares is still absent.
declare function wantOther(v: { other: string }): void;
export const n2 = wantOther({ ...u }); // TS2345
