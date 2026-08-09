// A TYPE-ONLY import binding is still the meaning of the name in a `typeof`
// TYPE QUERY: tsc gives the alias the target's full meaning and reports
// TS1361 only at VALUE positions, so the binding shadows a global of the
// same name here. Filtering it out of value space and letting the scope walk
// continue bound the DOM's `File`/`Blob` instead.
//
// expo-file-system is the shape this was found through: its native module
// declares `FileSystemFile: typeof File` against a type-only import, and
// `class File extends ExpoFileSystem.FileSystemFile` then inherited the
// DOM's `Blob` — so `uri`, `exists` and `open()` were all missing.

import type { File, Blob } from "./filesystem";

declare const fsModule: { FileSystemFile: typeof File };

// The base is the MODULE's `File`, not the DOM's.
declare class Derived extends fsModule.FileSystemFile {
  extra(): string;
}

export function useIt(): [number, string, boolean, string] {
  const d = new Derived();
  return [d.open(), d.uri, d.exists, d.extra()];
}

// Directly, too.
declare const ctor: typeof File;
export const madeHere: File = new ctor();
export const uri: string = madeHere.uri;

// And for a second colliding name, to show it is not one lucky global.
declare const bctor: typeof Blob;
export const bytes: number = new bctor().bytes;

// The TYPE meaning was never in doubt, but assert it stays the module's.
declare const b: Blob;
export const bBytes: number = b.bytes;

// NEGATIVE — a VALUE use of a type-only import is still TS1361.
export const bad = File;
