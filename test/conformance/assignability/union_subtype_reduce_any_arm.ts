// Subtype reduction of a `?:` / `||` / `??` union: which arm survives when
// the two are MUTUALLY assignable.
//
// tsc reduces with `strictSubtypeRelation`, in which `T` is a subtype of
// `any` but `any` is a subtype of nothing except `any` and `unknown`. So
// `string[] | any[]` is not a symmetric pair for tsc at all: the CONCRETE arm
// is the subtype, it is the arm that goes, and the result is `any[]`.
//
// ztsc's assignability relation relates `any` in both directions, so the arms
// come back mutually assignable and the reduction has to break the tie. It
// used to break it on the lower TypeId — which follows the demand order,
// which follows the ROOT FILE ORDER — so the winner moved when a program's
// `include` walk was permuted (excalidraw's `App.tsx` reported two TS7053s
// under `--file-order=reverse` and none under `source`). An ANY-ROOTED twin
// (`anyRooted`) now outranks its concrete counterpart, which is a property of
// the types.
//
// Every access below is the discriminator: with the `any` arm surviving the
// member is legal, exactly as it is for tsc. Had the concrete arm won, each
// would be a TS2339 on `string`.
declare const cond: boolean;
declare const items: string[];
declare const loose: any[];

const picked = cond ? items : loose;
const a1 = picked[0].notAProperty;

const orred = items.length ? loose : items;
const a2 = orred[0].notAProperty;

const nulled: string[] | null = cond ? items : null;
const a3 = (nulled ?? loose)[0].notAProperty;

// An `any` nested inside an OBJECT is deliberately NOT ranked (see
// `anyRooted`: selecting the any-carrying object twin would throw the other
// twin's properties away, which invents diagnostics — measured on social-app).
// tsgo still answers "the `any` arm" for both of these, and ztsc reaches the
// same answer here through the reached-first fallback; they are pinned so the
// pair stays checked, not because the rank decides them.
declare const anyRec: { [k: string]: any };
declare const strRec: { [k: string]: string };
const rec = cond ? strRec : anyRec;
const a4 = rec["k"].notAProperty;

declare const anyProp: { v: any };
declare const strProp: { v: string };
const prop = cond ? strProp : anyProp;
const a5 = prop.v.notAProperty;

// A member whose sibling is a STRICT subtype still reduces to the sibling's
// supertype with no tie-break involved: `string` is not assignable back to
// `string | number`, so nothing here depends on the rank at all.
declare const widened: string | number;
const narrowed = cond ? items[0] : widened;
const a6: string | number = narrowed;

void a1;
void a2;
void a3;
void a4;
void a5;
void a6;
