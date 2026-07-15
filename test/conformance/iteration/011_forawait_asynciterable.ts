// `for await…of`: async iterables, async generators, the sync-iterable
// fallback (elements awaited), and the TS2504 negative.
declare const ai: AsyncIterable<string>;
async function f() {
  for await (const s of ai) {
    const ok: string = s;
    const bad: number = s; // string -> number
  }
  for await (const t of ["a", "b"]) {
    const ok2: string = t;
    const bad2: number = t; // sync fallback: string -> number
  }
}
async function* g(): AsyncGenerator<boolean> {
  yield true;
  yield Promise.resolve(false); // yielded promises are awaited
}
async function h() {
  for await (const b of g()) {
    const bad3: number = b; // boolean -> number
  }
}
async function bad(x: number) {
  for await (const v of x) {
  } // not async-iterable
}
