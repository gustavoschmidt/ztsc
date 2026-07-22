// Spreading a value of an INTERSECTION type into an object literal gathers the
// properties of every constituent (a later constituent wins a name clash),
// mirroring tsc's spread over `A & B`. Previously an object-only guard skipped
// intersection sources, so `{ ...e }` produced an empty `{}` that then failed
// assignment to the very type it was spread from.
type Base = { type: string; value: string; note?: string };
type UC = Base & { id?: string; principal: boolean };
declare const e: UC;

// The spread carries Base's props plus the extra constituent's, so it satisfies
// the intersection it came from.
const copy: UC = { ...e };
const t: string = copy.type; // ok: `type` present
const p: boolean = copy.principal; // ok: required `principal` from the 2nd part

// A later constituent wins a name clash: `principal` here is required, not
// optional, so it is a `boolean` (never `undefined`).
type W = { principal?: boolean } & { principal: boolean };
declare const w: W;
const spreadW = { ...w };
const pw: boolean = spreadW.principal; // ok: required (2nd constituent won)

// Negative control: a property in NEITHER constituent is absent from the spread
// result, so accessing it is rejected (the gather is not a blanket `any`).
const bad = { ...e }.missing; // TS2339
