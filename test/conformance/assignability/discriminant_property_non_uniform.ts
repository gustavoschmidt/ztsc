// tsc's `isDiscriminantProperty`, the eligibility gate on
// `typeRelatedToDiscriminatedType`: the union's synthesized property must
// carry `CheckFlags.HasNonUniformType` (the constituents do not all give it
// the same type) AND `CheckFlags.HasLiteralType` (at least ONE of them gives
// it a unit type). Not "every constituent is a unit".
//
// The shape that distinction decides is a conditional that splits an optional
// key into "present as T" and "absent" -- react-navigation's
// `NavigatorID extends string ? { id: NavigatorID } : { id?: undefined }`
// instantiated at `string | undefined`. A value read back out of it has
// `id: string | undefined`, which fits neither constituent on its own.

type Split<ID extends string | undefined> = { a?: number } & (ID extends string ? { id: ID }
  : { id?: undefined });

declare const src: Split<string | undefined>;
declare const loose: { id: string | undefined; a: number | undefined };
declare const nolit: { k: string | number; x: boolean };
declare const extra: { id: string | undefined | 1 };

declare function take(o: Split<string | undefined>): void;

export function go() {
  const { id, a } = src;
  take({ id, a });
  const t1: Split<string | undefined> = { id, a };
  const t2: Split<string | undefined> = loose;
  const t3: { id: string } | { id?: undefined } = loose;

  // Each constituent on its OWN still rejects it -- only the by-cases split
  // accepts, which is the whole point.
  const t4: { a?: number } & { id: string } = loose; // TS2322
  const t5: { a?: number } & { id?: undefined } = loose; // TS2322

  // No unit type anywhere in the property: not a discriminant, so the union
  // is judged constituent by constituent and this still reports.
  const t6: { k: string; x: boolean } | { k: number; x: boolean } = nolit; // TS2322

  // A source constituent no member covers still reports.
  const t7: { id: string } | { id?: undefined } = extra; // TS2322

  return [t1, t2, t3, t4, t5, t6, t7];
}
