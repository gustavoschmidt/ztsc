// tsc's `checkTemplateExpression` keeps a template expression's structure —
// producing a template-literal TYPE rather than plain `string` — when the
// expression is in a CONST CONTEXT or has a template-literal contextual
// type: `isConstContext(node) || isTemplateLiteralContextualType(...)`.
// ztsc only had the contextual-type half, so `` `setUint${BITS[b]}` as const ``
// widened to `string` and could not index the accessor table — a TS7053
// false positive on the standard "compute the method name" idiom.

interface View {
  setUint8(o: number, v: number): void;
  setUint16(o: number, v: number): void;
  setUint32(o: number, v: number): void;
  getUint8(o: number): number;
  getUint16(o: number): number;
  getUint32(o: number): number;
}
declare function mkView(): View;

const BITS = { 1: 8, 2: 16, 4: 32 } as const;

export function access(bytes: 1 | 2 | 4, offset: number, value?: number) {
  if (value != null) {
    const setter = `setUint${BITS[bytes]}` as const;
    mkView()[setter](offset, value);
    return 0;
  }
  const getter = `getUint${BITS[bytes]}` as const;
  return mkView()[getter](offset);
}

// The indexed access distributes: the whole finite union is produced, and it
// is assignable to the spelled-out union (and to a narrower one only when it
// really is narrower — see the negatives file).
const all: "setUint8" | "setUint16" | "setUint32" = `setUint${
  BITS[1 as 1 | 2 | 4]
}` as const;
export const allNames = all;

// A single-valued placeholder collapses to one string literal.
const oneName: "setUint16" = `setUint${BITS[2]}` as const;
export const one = oneName;

// A nested const context (array / object literal / parenthesis) propagates,
// exactly as `isConstContext` recurses through those parents.
export const nested = [`setUint${BITS[bytesOf()]}`] as const;
declare function bytesOf(): 1 | 2 | 4;

// Without `as const` and without a contextual type, a template expression is
// still just `string`.
export const widened: string = `setUint${BITS[2]}`;
