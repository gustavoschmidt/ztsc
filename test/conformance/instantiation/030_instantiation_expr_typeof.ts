declare function make<T>(seed: T): { readonly seed: T };

// Type position: `typeof f<T>` is the instantiated signature.
type StringMaker = typeof make<string>;
declare const m: StringMaker;
const seeded: string = m("a").seed;
const wrong: number = m("a").seed;
m(1);
