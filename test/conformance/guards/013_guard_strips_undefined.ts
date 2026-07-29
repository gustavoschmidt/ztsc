// A user-defined type guard filters the union with the SUBTYPE relation
// (tsc `getNarrowedTypeWorker`), and `undefined`/`null` are subtypes of
// nothing but themselves — so a guard whose type is a "weak" object (every
// property optional) still strips them.
type Lib = { libraryItems?: number[]; library?: number[] };
declare function isValidLibrary(json: any): json is Lib;

export const f = (json: string) => {
  const data: Lib | undefined = JSON.parse(json);
  if (!isValidLibrary(data)) {
    throw new Error("x");
  }
  return data.libraryItems || data.library;
};

export const g = (data: Lib | undefined) => {
  if (isValidLibrary(data)) {
    return data.libraryItems;
  }
  return undefined;
};

// `null` too.
declare function isLib(x: unknown): x is Lib;
export const h = (v: Lib | null) => (isLib(v) ? v.library : []);

// A guard for a NARROWER type still narrows to it.
type Big = { a: number; b: number };
declare function isBig(x: unknown): x is Big;
export const i = (v: { a: number } | undefined) => (isBig(v) ? v.b : 0);
