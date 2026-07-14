// `infer` binds a type by structurally matching the check type against the
// extends pattern.
type Elem<T> = T extends Array<infer U> ? U : never;

const a: Elem<number[]> = 5;
const b: Elem<string[]> = "x";
const c: Elem<number[]> = "x"; // wrong -> TS2322

// infer from a tuple's element position.
type First<T> = T extends [infer H, ...unknown[]] ? H : never;
const d: First<[boolean, string]> = true;
const e: First<[boolean, string]> = "x"; // wrong -> TS2322

// Non-matching check falls to the false branch (never), so `never` is the
// only assignable value type — assigning anything else is an error.
type OnlyArr<T> = T extends Array<infer U> ? U : never;
const f: OnlyArr<number> = 5; // never <- 5 : TS2322
