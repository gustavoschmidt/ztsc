export {};

// A reopen in ANOTHER file that omits the type-parameter list entirely —
// legal because every parameter of `Box` has a default. It must not erase
// them, and its own `this`-returning member must still denote the whole
// merged interface (so it relates to the base's `self(): this`).
declare global {
  interface Box {
    self(): this;
    label(): string;
  }
}
