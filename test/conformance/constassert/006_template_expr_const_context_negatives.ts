// The precision the const context buys is real, not a suppression: the
// template-literal type it produces is still checked.

const BITS = { 1: 8, 2: 16, 4: 32 } as const;

// The finite union does not fit a single member of it.
const tooWide: "setUint8" = `setUint${BITS[1 as 1 | 2 | 4]}` as const;
export const a = tooWide;

// A name the table cannot produce.
const wrong: "setUint64" = `setUint${BITS[4]}` as const;
export const b = wrong;

// A key the table does not have is still an implicit-`any` element access,
// not a silent `number`.
export const missing = BITS[3];

// The element type the access produces is checked like any other.
const wrongElem: string = BITS[2];
export const d = wrongElem;
