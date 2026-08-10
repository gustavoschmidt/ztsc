// `typeRelatedToDiscriminatedType` takes the cross product of the SOURCE's
// discriminant property types and requires every combination to match some
// target constituent:
//
//     sourceDiscriminantTypes[i] = sourcePropertyType.flags & TypeFlags.Union
//       ? (sourcePropertyType as UnionType).types
//       : [sourcePropertyType];
//
// tsc models an ENUM type as the union of its member types, so a source
// discriminant typed by the whole enum splits across the target's per-member
// constituents. ztsc models an enum as ONE nominal type, so the cross product
// had a single element that matched no constituent.
//
// The other half is that each target constituent's discriminant lives in an
// INTERSECTION: `getPropertyOfType` intersects the constituents' property
// types and `getIntersectionType` drops the redundant base primitive
// (`removeRedundantPrimitiveTypes`), so `{id: string} & {id: Nux.A}` has
// `id: Nux.A`. ztsc's store deliberately leaves enum members out of that
// reduction, so the pair stayed live as `string & Nux.A` and the discriminant
// scan rejected it as non-unit.
//
// bluesky's `saveNux({id, completed: true, data: undefined})` needs both.

enum Nux {
  A = "a",
  B = "b",
  C = "c",
}

type Base = {completed: boolean; expiresAt?: string; id: string};
type AppNux =
  | (Base & {data: undefined; id: Nux.A})
  | (Base & {data: undefined; id: Nux.B})
  | (Base & {data: undefined; id: Nux.C});

declare function saveNux(n: AppNux): void;
declare const id: Nux;

export const ok = saveNux({id, completed: true, data: undefined});

// A single enum member still works the ordinary way.
export const okOne = saveNux({id: Nux.A, completed: true, data: undefined});

// A plain string-literal union discriminant (the control that already worked).
type Base2 = {completed: boolean; id: string};
type App2 = (Base2 & {id: "a"}) | (Base2 & {id: "b"});
declare function save2(n: App2): void;
declare const l: "a" | "b";
export const okLit = save2({id: l, completed: true});

// --- what must still report -------------------------------------------------
// A discriminant value no constituent carries.
enum Other {
  Z = "z",
}
declare const z: Other;
export const badTag = saveNux({id: z, completed: true, data: undefined});

// A non-discriminant property that no matching constituent accepts.
export const badProp = saveNux({id, completed: "yes", data: undefined});

// The enum only covers PART of the target: `Nux.C` has no constituent here.
type App3 = (Base & {data: undefined; id: Nux.A}) | (Base & {data: undefined; id: Nux.B});
declare function save3(n: App3): void;
export const badPartial = save3({id, completed: true, data: undefined});
