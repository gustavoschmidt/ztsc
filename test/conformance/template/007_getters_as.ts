// The M16b `as`-remap idiom, now with a template-literal rename (M16c).
type Getters<T> = { [K in keyof T as `get${Capitalize<K & string>}`]: () => T[K] };
type G = Getters<{ name: string; age: number }>;
declare const g: G;
const n: string = g.getName();
const a: number = g.getAge();
const bad = g.getName;      // ok (method value)
const missing = g.fetch();  // no such property -> TS2339
