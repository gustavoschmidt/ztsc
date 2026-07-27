// A MODULE (top-level `export {}`) that contributes a global augmentation —
// the `vitest/globals.d.ts` shape. Its `expect` is a global CONTRIBUTION, not
// a global declaration: it merges after every script's top level.
export {};

interface ExpectStatic {
  vitestOnly(): void;
}

declare global {
  const expect: ExpectStatic;
}
