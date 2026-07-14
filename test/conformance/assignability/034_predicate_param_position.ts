class Dog { d!: number; }

declare const guardX: (x: unknown, y: unknown) => x is Dog;
declare const guardY: (x: unknown, y: unknown) => y is Dog;

// a predicate guarding a different parameter position is not assignable
const p1: (x: unknown, y: unknown) => x is Dog = guardY;
// same guarded position
const p2: (x: unknown, y: unknown) => x is Dog = guardX;
