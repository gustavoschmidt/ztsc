class Dog { d!: number; }

declare const guardDog: (x: unknown) => x is Dog;
declare const plainBool: (x: unknown) => boolean;

// a predicate source satisfies a plain-boolean target
const b1: (x: unknown) => boolean = guardDog;
// a plain-boolean source does NOT satisfy a predicate target
const b2: (x: unknown) => x is Dog = plainBool;
