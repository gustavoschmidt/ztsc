// TS2309 ("export assignment cannot be used in a module with other exported
// elements") is about ONE module, and one `.d.ts` routinely holds several
// `declare module "…"` blocks. A file-wide scan reported it on `@types/node`'s
// `events.d.ts`, where `export = EventEmitter` in one block sits next to an
// unrelated `export { … }` in another.
declare module "a1" {
  class S {
    m(): void;
  }
  export = S;
}

declare module "b1" {
  const y: number;
  export { y };
}

// Still an error when the mixing really is inside one module.
declare module "c1" {
  const z: number;
  export { z };
  export = z;
}
