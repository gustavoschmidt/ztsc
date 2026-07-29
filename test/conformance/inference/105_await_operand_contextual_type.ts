// The operand of `await` is contextually typed by `T | Promise<T>` (tsc's
// contextual type for an await operand, the same convention the async-return
// arm uses). Checking it context-free left a GENERIC operand's type parameter
// with no candidate, so it took its DEFAULT.

type Promisable<T> = T | Promise<T>;
type MockFactory<M = unknown> = (
  importOriginal: <T extends M = M>() => Promise<T>,
) => Promisable<Partial<M>>;

declare function mock(path: string, factory?: MockFactory<unknown>): void;

mock("../data/blob", async (actual) => {
  const orig: Object = await actual();
  return { ...orig, extra: 1 };
});

// The same helper reached without the alias instantiation.
declare const g: <T extends unknown = unknown>() => Promise<T>;
export async function h() {
  const a: Object = await g();
  const b: { a: number } = await g();
  return [a, b];
}

// A buried type parameter with a default still infers from the awaited
// contextual type rather than defaulting.
declare const load: <T = string>() => Promise<T>;
export async function i() {
  const n: number = await load();
  return n;
}

// Control: a param that IS the whole return type still takes its default when
// only a contextual type is available (no structural evidence).
declare const dispatchOf: <AD extends { t: string } = { t: string }>() => AD;
export function j() {
  const d: { t: string } = dispatchOf();
  return d;
}

// Control: awaiting a non-generic promise is unchanged.
declare const p: Promise<number>;
export async function k() {
  const n: number = await p;
  return n;
}
