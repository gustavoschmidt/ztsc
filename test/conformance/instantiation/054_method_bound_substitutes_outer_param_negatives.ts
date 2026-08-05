// The negative control for `054_method_bound_substitutes_outer_param.ts`: a
// substituted bound is still a bound.

interface Shape {
  id: string;
  count: number;
}

interface Reader<T> {
  get<K extends keyof T>(k: K): T[K];
}
declare const r: Reader<Shape>;
r.get('nope');

// A bound that goes through a mapped type still rejects a key the map does
// not produce.
type OnlyStrings<T> = { [K in keyof T as T[K] extends string ? K : never]: T[K] };
interface Reader2<T> {
  get<K extends keyof OnlyStrings<T>>(k: K): void;
}
declare const r2: Reader2<Shape>;
r2.get('count');

export {};
