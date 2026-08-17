// tsc's `narrowTypeByTypePredicate` optional-chain arm: when the guarded
// argument is an optional chain CONTAINING the reference, the branch narrows
// that receiver to non-null — on BOTH branches, whatever the predicate
// asserts. (tsc's only exemption is the `exactOptionalPropertyTypes` missing
// type, which no ordinary predicate mentions.)
interface Animal {
  breed?: Breed;
}
interface Breed {
  size?: string;
}

declare function isNil(value: unknown): value is undefined | null;
declare function isString(value: unknown): value is string;

// Guard asserts a nullish type, taken as FALSE.
function refutedNullish(animal: Animal): string | undefined {
  if (!isNil(animal?.breed?.size)) {
    return animal.breed.size;
  }
  return undefined;
}

// Guard asserts a non-nullish type, taken as TRUE.
function assertedString(animal: Animal): string | undefined {
  if (isString(animal?.breed?.size)) {
    return animal.breed.size;
  }
  return undefined;
}

// The reference is the ARGUMENT itself, not a receiver inside it: the
// ordinary predicate narrowing, unchanged.
function argumentItself(size: string | undefined): string {
  if (isString(size)) {
    return size;
  }
  return "";
}

export { refutedNullish, assertedString, argumentItself };
