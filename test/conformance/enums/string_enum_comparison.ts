// tsc's *comparable* relation (used for the TS2367 "no overlap" check) treats a
// string enum as overlapping a string literal equal to one of its member
// values, even though the plain literal is not *assignable* into the nominal
// string enum. So `sex === 'FEMALE'` is a legitimate comparison, but
// `sex === 'ZEBRA'` (no member has that value) is TS2367. Minimized repro of the
// dogfood project's `cattle.sex === 'FEMALE'` icon guards.

enum CattleSex {
  Male = "MALE",
  Female = "FEMALE",
}

declare const sex: CattleSex;

// POSITIVE (must NOT error): the literal matches a member value.
const a = sex === "FEMALE" ? 1 : 2;
const b = sex === "MALE" ? 1 : 2;
const c = sex !== "FEMALE";
void a;
void b;
void c;

// NEGATIVE CONTROL (MUST error TS2367): no member has this value.
const d = sex === "ZEBRA" ? 1 : 2;
void d;

// A numeric enum ↔ number literal already overlaps on a member value and
// rejects a non-member value (regression coverage for the existing path).
enum Dir {
  Up = 1,
  Down = 2,
}
declare const dir: Dir;
const e = dir === 1 ? 1 : 2; // OK: member value
void e;
const f = dir === 99 ? 1 : 2; // error TS2367: no member value 99
void f;
