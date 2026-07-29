// A trailing rest typed by a fixed TUPLE is the parameter list, so an optional
// tuple ELEMENT is an optional parameter: its type at that position is
// `T | undefined`, exactly as a `?`-marked parameter's is. Reading only the
// parameter flags left the position's type bare, and the contravariant
// relation then compared an optional target parameter (which does carry
// `undefined`) against a source that refused it.

interface OtrOpts {
  count?: number;
  loud?: false;
}

declare function otrRest(...args: [key: string, options?: OtrOpts]): string;
const otrTarget: (key: string, options?: { count?: number }) => string = otrRest;

declare function otrPlain(key: string, options?: OtrOpts): string;
const otrTarget2: (key: string, options?: { count?: number }) => string =
  otrPlain;

// The same through a generic erased to its constraint.
declare function otrGeneric<T extends OtrOpts>(
  ...args: [key: string, options?: T]
): string;
const otrTarget3: (key: string, options?: { count?: number }) => string =
  otrGeneric;

// A REQUIRED tuple element is still required: the target may not omit it.
declare function otrReq(...args: [key: string, options: OtrOpts]): string;
const otrTarget4: (key: string, options: { count?: number }) => string = otrReq;
