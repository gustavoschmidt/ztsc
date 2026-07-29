// Negatives: making an optional tuple element admit `undefined` must not make
// the position accept anything else, and a required element stays required.

interface OtnOpts {
  count?: number;
}

declare function otnRest(...args: [key: string, options?: OtnOpts]): string;

// The element type still has to relate: a target parameter the source cannot
// accept is still an error.
const otnBad1: (key: string, options?: { count?: string }) => string = otnRest;

// A required source parameter still refuses an optional target parameter.
declare function otnReq(...args: [key: string, options: OtnOpts]): string;
const otnBad2: (key: string, options?: OtnOpts) => string = otnReq;

// The return type is unaffected.
const otnBad3: (key: string, options?: OtnOpts) => number = otnRest;

// And the first element is still required.
const otnBad4: (key?: string, options?: OtnOpts) => string = otnRest;
