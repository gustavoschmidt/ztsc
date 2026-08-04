// A key-remapped mapped type may not be materialized while its `as` clause
// still mentions a type parameter nothing has bound yet.
//
// Deferral used to be decided by the KEY SET alone, on the reasoning that the
// value and `as` branches "materialize into generic-typed props". That holds
// for the value branch and not for the remap: the remap NAMES the property, so
// it is evaluated per key, and a remap that does not reduce to a literal (or to
// `never`) drops the key. An undecidable remap therefore deleted every key
// instead of deferring — and the key set here is perfectly concrete, so nothing
// else caught it.
//
// The shape is the `Omit`-by-another-shape idiom, applied where the two shapes
// are bound at DIFFERENT times: `Shape` comes from the receiver and `U` only
// from the call. zod's `util.Extend` is written exactly this way and reached
// through `ZodObject.extend<U>(shape: U)`, so every property an overriding
// `.extend({…})` did not redeclare vanished from the schema — immich's
// `LargeAssetSearchDto` lost `visibility`, while the sibling built by an
// extension that adds only NEW keys kept it (that one takes `Extend`'s cheap
// `A & B` branch and never reaches the remap).

type Identity<T> = T;
type Flatten<T> = Identity<{ [k in keyof T]: T[k] }>;

type Extend<A extends object, B extends object> = Flatten<
  keyof A & keyof B extends never
    ? A & B
    : {
        [K in keyof A as K extends keyof B ? never : K]: A[K];
      } & {
        [K in keyof B]: B[K];
      }
>;

interface Obj<Shape extends object> {
  shape: Shape;
  extend<U extends object>(shape: U): Obj<Extend<Shape, U>>;
}

declare const base: Obj<{ visibility?: string; withDeleted?: boolean; size?: number }>;

// `size` is redeclared, so `keyof A & keyof B` is not `never` and the remap arm
// runs. Everything the extension did not redeclare has to survive it.
const overlapping = base.extend({ minFileSize: 1 as number | undefined, size: 2 as number | undefined });
type Overlapping = typeof overlapping.shape;
declare const o: Overlapping;

export const a: string | undefined = o.visibility;
export const b: boolean | undefined = o.withDeleted;
export const c: number | undefined = o.size;
export const d: number | undefined = o.minFileSize;

// The other arm, for contrast: no shared key, so `A & B` and no remap at all.
const disjoint = base.extend({ withPeople: true as boolean | undefined });
type Disjoint = typeof disjoint.shape;
declare const j: Disjoint;

export const e: string | undefined = j.visibility;
export const f: boolean | undefined = j.withPeople;

// Negative control: the remap still filters when it CAN be decided, so a key
// the extension does redeclare is not left behind with its old type.
type Remapped = Extend<{ size?: number }, { size?: string }>;
declare const r: Remapped;
export const g: number | undefined = r.size;
