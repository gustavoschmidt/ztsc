class Animal { a!: number; }
class Dog extends Animal { d!: number; }
class Cat extends Animal { c!: number; }

declare const guardDog: (x: unknown) => x is Dog;
declare const guardAnimal: (x: unknown) => x is Animal;

// sub-predicate is assignable to a super-predicate (covariant asserted type)
const g1: (x: unknown) => x is Animal = guardDog;
// super-predicate is NOT assignable to a sub-predicate
const g2: (x: unknown) => x is Dog = guardAnimal;
// unrelated predicates
const g3: (x: unknown) => x is Cat = guardDog;
// identical predicates
const g4: (x: unknown) => x is Dog = guardDog;
