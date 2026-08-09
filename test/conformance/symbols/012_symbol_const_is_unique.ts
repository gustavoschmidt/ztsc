// tsc's `getESSymbolLikeTypeForNode`: a call to the global `Symbol` /
// `Symbol.for` gets a FRESH `unique symbol` type — not the plain `symbol`
// its signature returns — when it initializes a declaration that can hold
// one, which for a variable means a `const` with an identifier name. No
// `unique symbol` ANNOTATION is required.
//
// The consequence is narrowing: a `unique symbol` is one of tsc's UNIT
// types, so a sentinel const subtracts itself from a union under `===`.
// Left as plain `symbol`, `=== SENTINEL` narrowed nothing.

export const TOMBSTONE = Symbol("tombstone");
const REGISTERED = Symbol.for("registered");

interface Post {
  uri: string;
  text: string;
}

declare const shadowed: Post | typeof TOMBSTONE;

export function render(): string {
  if (shadowed === TOMBSTONE) return "";
  // The sentinel is gone, so the post's own properties are here.
  return shadowed.uri + shadowed.text;
}

export function renderPositive(): symbol {
  if (shadowed === TOMBSTONE) return shadowed;
  return TOMBSTONE;
}

declare const registered: Post | typeof REGISTERED;
export function render2(): string {
  if (registered === REGISTERED) return "";
  return registered.uri;
}

// A plain `symbol` is NOT narrowed down to the sentinel by `===` (verified
// against the oracle): it stays `symbol`, so this return is TS2322.
declare const anySym: symbol;
export function pick(): typeof TOMBSTONE | undefined {
  if (anySym === TOMBSTONE) return anySym;
  return undefined;
}

// Two sentinels are distinct nominal types.
export const OTHER = Symbol("other");
declare const two: typeof TOMBSTONE | typeof OTHER;
export function which(): string {
  if (two === TOMBSTONE) return "tomb";
  const rest: typeof OTHER = two;
  return rest === OTHER ? "other" : "?";
}

// A `let` is NOT a valid unique-symbol declaration: it stays plain `symbol`.
let mutable = Symbol("mutable");
mutable = Symbol("replaced");
export const stillSymbol: symbol = mutable;

// NEGATIVES.
export const bad1: never = TOMBSTONE;
export const bad2: typeof OTHER = TOMBSTONE;
declare const notShadowed: Post | typeof TOMBSTONE;
export const bad3: string = notShadowed.uri;
