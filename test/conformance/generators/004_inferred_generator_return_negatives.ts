// The inferred `Generator<Y, R, unknown>` is a real type, so the wrong one is
// rejected.

function* strings() {
  yield "a";
}

// Y is `string`, not `number`.
export const a: Generator<number, void, unknown> = strings();

// R is `void`, not `string`.
export const b: Generator<string, string, unknown> = strings();

function* withReturn() {
  yield 1;
  return "done";
}

// R is `string`, not `number`.
export const cc: Generator<number, number, unknown> = withReturn();

// The yielded element type flows into iteration.
export function collect(): number[] {
  const out: number[] = [];
  for (const v of strings()) {
    out.push(v);
  }
  return out;
}
