// Relating a deferred `keyof T` through `string | number | symbol` must not
// make the cast test vacuous: a source outside the key domain still has no
// overlap with a key type.
declare const o: { a: 1 };
declare const b: boolean;
declare const arr: string[];
declare const s: string;

export function objectSource<T extends object>() {
  return o as keyof T;
}
export function booleanSource<T extends object>() {
  return b as keyof T;
}
export function arraySource<T extends object>() {
  return arr as keyof T;
}
// a concrete keyof is still a plain literal union, and a non-key source is
// still a mistake
export const concreteBad = b as keyof { x: 1; y: 2 };
// and the ordinary non-keyof cases are untouched
export const plainBad = s as number;
