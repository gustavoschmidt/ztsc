// An unannotated `function*` infers `Generator<Y, R, unknown>`: `Y` unions the
// yielded values (widened), `R` is the body's ordinary inferred return type.

function* strings() {
  yield "a";
  yield "b";
}
export const s: Generator<string, void, unknown> = strings();

function* mixed() {
  yield 1;
  yield "a";
}
export const m: Generator<string | number, void, unknown> = mixed();

function* none() {}
export const n: Generator<never, void, unknown> = none();

function* bare() {
  yield;
}
export const b: Generator<undefined, void, unknown> = bare();

function* withReturn() {
  yield 1;
  return "done";
}
export const w: Generator<number, string, unknown> = withReturn();

// A nested arrow's body is not this generator's.
function* nested() {
  const f = () => 1;
  yield f();
}
export const nf: Generator<number, void, unknown> = nested();

class Holder {
  *keys() {
    yield "k";
  }
}
export const h: Generator<string, void, unknown> = new Holder().keys();

// The inferred yield type is what an iteration sees.
export function collect(): string[] {
  const out: string[] = [];
  for (const v of strings()) {
    out.push(v);
  }
  return out;
}

// An explicit annotation still wins.
function* annotated(): Generator<number> {
  yield 1;
}
export const a: Generator<number> = annotated();
