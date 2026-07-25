// A `return` expression in an async function is contextually typed by
// `T | Promise<T>` (tsc's getContextualTypeForReturnExpression). A generic
// `new` whose own return is `Promise<...>` and that has no argument evidence
// for its type parameter therefore infers it from the awaited payload of the
// enclosing return annotation.
interface User {
  name: string;
}

// `new Promise(() => {})` -> Promise<User> from the context. Without the
// contextual reach it is Promise<unknown> and `unknown` fails `User` (TS2322).
async function pending(): Promise<User> {
  return new Promise(() => {});
}

// The resolving-executor form also infers the payload, so `resolve(1)` typechecks.
async function later(): Promise<number> {
  return new Promise((resolve) => resolve(1));
}

// Negative control: an explicit, incompatible type argument still errors — the
// context only *fills* an otherwise-uninferred parameter, never overrides one.
async function wrong(): Promise<number> {
  return new Promise<string>((resolve) => resolve('s'));
}
