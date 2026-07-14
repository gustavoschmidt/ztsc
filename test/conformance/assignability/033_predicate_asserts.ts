class Animal { a!: number; }
class Dog extends Animal { d!: number; }

declare const assertDog: (x: unknown) => asserts x is Dog;
declare const assertAnimal: (x: unknown) => asserts x is Animal;
declare const guardDog: (x: unknown) => x is Dog;
declare const plainBool: (x: unknown) => boolean;

// a void-returning asserts target accepts a mismatched asserts source
const s1: (x: unknown) => asserts x is Dog = assertAnimal;
// an asserts target accepts a plain predicate source
const s2: (x: unknown) => asserts x is Dog = guardDog;
// an asserts target accepts a plain boolean source
const s3: (x: unknown) => asserts x is Dog = plainBool;
// an asserts source is NOT assignable to a plain predicate target
const s4: (x: unknown) => x is Dog = assertDog;
