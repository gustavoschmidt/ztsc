// Every declaration in a `.d.ts` is ambient (`NodeFlags.Ambient`), so
// `strictPropertyInitialization` never looks at it — no `declare` keyword
// needed on the class, and no constructor body to analyze. This is the
// highest-volume form of the exemption by far: `node_modules` is nothing but
// declaration files full of `class X { a: string }`.
export declare class Plain {
  a: string;
  b: number;
  constructor(a: string);
}

export declare abstract class Abstract {
  a: string;
  abstract b: string;
}

export interface Shape {
  a: string;
}
