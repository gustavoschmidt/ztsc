// A plain global SCRIPT (no import/export) — the `@types/jest/index.d.ts`
// shape. Its whole top level is a global declaration.
declare namespace jest {
  interface Expect {
    plainJest(): void;
  }
}

declare var expect: jest.Expect;
