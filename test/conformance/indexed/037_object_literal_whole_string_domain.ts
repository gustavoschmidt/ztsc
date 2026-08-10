// An OBJECT LITERAL indexed by the whole `string` domain is not an
// implicit-any element access. tsc's `getPropertyTypeForIndexType`, once the
// index-signature lookup has missed:
//
//   if (accessExpression && !isConstEnumObjectType(objectType)) {
//     if (isObjectLiteralType(objectType)) {
//       ...
//       else if (indexType.flags & (TypeFlags.Number | TypeFlags.String)) {
//         const types = map(getPropertiesOfType(objectType), getTypeOfSymbol);
//         return getUnionType(append(types, undefinedType));
//       }
//     }
//   }
//
// — the union of every property type plus `undefined`, with NO diagnostic.
// That is what types the inline lookup-table idiom; ztsc reported TS7053.

declare const weight: string | number | undefined;

export const family =
  {
    400: "Inter-Regular",
    500: "Inter-Medium",
    700: "Inter-Bold",
  }[String(weight || "400")] || "Inter-Regular";

// The result really is `union | undefined`, not `any`.
declare const k: string;
const mixed = {a: 1, b: "x"}[k];
export const ok: number | string | undefined = mixed;
export const notNarrower: number = mixed;

// --- what must still report -------------------------------------------------
// An interface is not an object-literal type.
interface I {
  a: number;
}
declare const i: I;
export const badIface = i[k];

// Nor is a type literal on an annotated declaration — the flag is set by the
// object-literal EXPRESSION, not by the shape.
declare const o: {a: number};
export const badLit = o[k];

// A string-index signature still wins over the fallback.
declare const rec: {[key: string]: number};
export const viaIndex: number = rec[k];
