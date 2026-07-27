export {};

// The block that carries the type-parameter list AND the `extends` clause.
declare global {
  interface Holder<T> {
    self(): this;
    payload: T;
  }
  interface Box<T = string> extends Holder<T> {
    narrow(): Box<T>;
  }
}
