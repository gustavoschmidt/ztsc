// An INTERSECTION contextual type admits a literal when ANY of its members
// does — tsc's `isLiteralOfContextualType` tests a union and an intersection
// the same way (`flags & UnionOrIntersection` → `some(types, …)`).
//
// A property of `Settings & { leading: true }` gets exactly that: the members
// are `boolean | undefined` and `true`. Without the rule the fresh `true`
// widened to `boolean`, which no longer matched the `{ leading: true }` arm.

interface Settings {
  leading?: boolean;
  trailing?: boolean;
}

type Isect = Settings & { leading: true };
type Ored = (Settings & { leading: true }) | { trailing?: boolean };

export const a: Isect = { leading: true, trailing: false };
export const b: Ored = { leading: true, trailing: false };

interface Named {
  kind?: string;
  n?: number;
}
type NamedIsect = Named & { kind: "x"; n: 1 };
export const c: NamedIsect = { kind: "x", n: 1 };

// The overload that only the un-widened literal can select.
declare function pick<T extends (...args: any) => any>(f: T, o?: Ored): "A";
declare function pick<T extends (...args: any) => any>(f: T, o?: Settings): "B";
export const d: "A" = pick(() => {}, { leading: true, trailing: false });
