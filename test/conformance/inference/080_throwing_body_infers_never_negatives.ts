// Only an UNREACHABLE endpoint infers `never`; a body that can fall off the
// end is still `void`, and `void` still does not satisfy a value return.
const plain = () => {
  const x = 1;
};
export const a: () => number = plain;

// A conditional throw does not make the endpoint unreachable.
const maybe = (b: boolean) => {
  if (b) {
    throw new Error("boom");
  }
};
export const b: (x: boolean) => string = maybe;

// `never` is not a source for everything in the other direction.
const thrower = () => {
  throw new Error("boom");
};
export const cc: number = thrower;
