// The guard only strips nullish that the guarded type does not itself admit,
// and the FALSE branch keeps it.
type Lib = { libraryItems?: number[] };
declare function isValidLibrary(json: any): json is Lib;

// False branch: `undefined` survives, and so does `Lib`.
export const f = (data: Lib | undefined) => {
  if (!isValidLibrary(data)) {
    return data.libraryItems;
  }
  return undefined;
};

// A guard whose type ADMITS `undefined` keeps it.
declare function isMaybeLib(x: unknown): x is Lib | undefined;
export const g = (data: Lib | undefined) => {
  if (isMaybeLib(data)) {
    return data.libraryItems;
  }
  return undefined;
};

// A guard on a subject that is ONLY nullish leaves `never`, so nothing can be
// assigned to it.
declare function isLib(x: unknown): x is Lib;
export const h = (v: undefined) => {
  if (isLib(v)) {
    const z: typeof v = { libraryItems: [] };
    return z;
  }
  return undefined;
};
