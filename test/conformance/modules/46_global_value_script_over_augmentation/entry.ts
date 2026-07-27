// Two files declare the global `expect`: a module's `declare global { const
// expect: ExpectStatic }` (referenced FIRST, so it is bound first) and a
// script's `declare var expect: jest.Expect`. The script wins the VALUE
// declaration regardless of load order — a global augmentation merges after
// every script's top level and does not take over an existing one — so
// `expect` is `jest.Expect`, with the reopened members merged in, and the
// augmentation's own member is not there.
//
// (`skipLibCheck` is on, as in the real jest + vitest project: the `var` vs
// `const` clash is a TS2451 in each declaration file, suppressed there.)
/// <reference path="./vitest_globals.d.ts" />
/// <reference path="./jest_globals.d.ts" />
/// <reference path="./custom_matchers.d.ts" />

export const a = expect.plainJest();
export const b = expect.toBeNonNaNNumber();
export const c = expect.vitestOnly();
