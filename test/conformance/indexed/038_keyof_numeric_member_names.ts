// `keyof` over a member declared with a NUMERIC name yields the NUMBER
// literal, not the string of its digits — tsc's
// `getLiteralTypeFromPropertyName` types the name NODE, so a numeric literal
// name checks as a numeric literal. A QUOTED name is a string literal even
// when its digits read as a number, and the two are not assignable either way.
//
// ztsc keys every member table by atom, so `keyof { 200: A }` came back
// `'200'` and octokit's `SuccessStatuses & keyof Responses` — numeric HTTP
// status codes on both sides — intersected to `never`; every
// `Endpoints[…]['response']` read then came out `unknown` and each property
// off it was a TS2339 (outline, 35 of them). The number literal is recorded as
// the member's tsc `nameType` (`Checker.memberNameType`, kept in
// `Checker.key_name_types`).

interface Responses {
  200: { ok: number };
  304: { cached: number };
  404: { missing: number };
}

// The key set IS the numeric literal union.
declare const rk: keyof Responses;
export const rk1: 200 | 304 | 404 = rk;
export const rk2: number = rk;
// …and NOT the string union.
export const rkBad: '200' | '304' | '404' = rk;

// So an intersection with an unrelated numeric union survives.
type Success = 200 | 201 | 204;
type SK = Success & keyof Responses;
declare const sk: SK;
export const sk1: 200 = sk;

// The mapped-type + indexed-access idiom octokit is built on.
type Picked = { [K in SK]: Responses[K] }[SK];
declare const p: Picked;
export const p1: { ok: number } = p;

// A QUOTED numeric name stays a string literal.
interface Quoted {
  '200': { ok: number };
}
declare const qk: keyof Quoted;
export const qk1: '200' = qk;
export const qkBad: 200 = qk;

// A COMPUTED numeric name, and a computed key naming a numeric const, are
// both numeric too — the atom is the same digits either way.
type Computed = { [200]: 1 };
declare const ck: keyof Computed;
export const ck1: 200 = ck;
export const ckBad: '200' = ck;

const two: 200 = 200;
type ComputedConst = { [two]: 1 };
declare const cck: keyof ComputedConst;
export const cck1: 200 = cck;
export const cckBad: '200' = cck;

// A fractional name is the number it spells; a quoted one that is NOT the
// number's canonical rendering stays the string it was written as.
type Frac = { 1.5: 1 };
declare const fk: keyof Frac;
export const fk1: 1.5 = fk;
type FracQuoted = { '1.50': 1 };
declare const fqk: keyof FracQuoted;
export const fqk1: '1.50' = fqk;
export const fqkBad: 1.5 = fqk;

// A negative-looking name is not numeric syntax at all (`-1` cannot be a
// property name; only `'-1'` can), so it is the string.
type Neg = { '-1': 1 };
declare const nk: keyof Neg;
export const nk1: '-1' = nk;

// Mixed tables keep each member's own answer, and index-signature domains
// still join the union.
interface Mixed {
  200: 1;
  ok: 2;
  '304': 3;
}
declare const mk: keyof Mixed;
export const mk1: 200 | 'ok' | '304' = mk;

// Indexed access reads the member under either spelling of the key, and the
// numeric key still satisfies a `number` index signature.
export const a1: Responses[200] = { ok: 1 };
export const a2: Responses['200'] = { ok: 1 };
type NumIndex = { [k: number]: { ok: number } };
export const ni: NumIndex = { 200: { ok: 1 } };

// `keyof` split by the primitive it belongs to.
type Keep<T, U> = T extends U ? T : never;
type Drop<T, U> = T extends U ? never : T;
type OnlyNumbers = Keep<keyof Mixed, number>;
type OnlyStrings = Keep<keyof Mixed, string>;
declare const on: OnlyNumbers;
declare const os: OnlyStrings;
export const on1: 200 = on;
export const os1: 'ok' | '304' = os;

// A numeric METHOD name is named the same way.
interface NumMethod {
  200(): void;
}
declare const nmk: keyof NumMethod;
export const nmk1: 200 = nmk;

// Excluding off the numeric key set, as `Omit` does it.
type WithoutOk = Drop<keyof Mixed, 'ok'>;
declare const wo: WithoutOk;
export const wo1: 200 | '304' = wo;
