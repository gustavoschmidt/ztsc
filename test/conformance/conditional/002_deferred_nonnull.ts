// A generic conditional stays deferred while its check type is generic, and
// resolves on instantiation. NonNull is used both generically (inside another
// generic alias) and at concrete instantiations.
type NonNull<T> = T extends null | undefined ? never : T;

const a: NonNull<string> = "x";
const b: NonNull<string | null> = "x";
const c: NonNull<string | null | undefined> = "x";

// Removing null/undefined means assigning null is an error.
const d: NonNull<string | null> = null;

// Used generically: the conditional is deferred through another type param.
type Clean<T> = NonNull<T>;
const e: Clean<number | undefined> = 5;
const f: Clean<number | undefined> = undefined;
