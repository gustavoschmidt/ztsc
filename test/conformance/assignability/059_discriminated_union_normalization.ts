// A source object whose discriminant property is a union is assignable to a
// union target that splits that discriminant across members differing only in
// it (tsc typeRelatedToDiscriminatedType), even though it matches no single
// member on its own.
type U =
  | { ids: string[]; type: 'created'; areaType: string }
  | { ids: string[]; type: 'edited'; areaType: string }
  | { ids: string[]; type: 'deleted'; areaType: string };

declare const s: { ids: string[]; type: 'created' | 'edited' | 'deleted'; areaType: string };
const ok: U = s; // ok — every discriminant constituent is covered

// A non-discriminant property mismatch is still rejected.
declare const bad: { ids: number[]; type: 'created' | 'edited'; areaType: string };
const no: U = bad; // TS2322: ids: number[] not assignable to string[]

// A discriminant constituent with no matching member is rejected.
declare const extra: { ids: string[]; type: 'created' | 'renamed'; areaType: string };
const no2: U = extra; // TS2322: 'renamed' matches no member

export { ok, no, no2 };
