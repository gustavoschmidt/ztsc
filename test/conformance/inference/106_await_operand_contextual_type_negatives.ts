// Negatives for 105: the contextual type must not make an await accept what
// the operand cannot produce, and the constraint still binds.

declare const load: <T extends { a: number } = { a: number }>() => Promise<T>;

// The contextual type does not satisfy `T`'s constraint.
export async function f() {
  const x: { b: string } = await load();
  return x;
}

declare const p: Promise<number>;
// A concrete promise payload is still checked against the annotation.
export async function g() {
  const n: string = await p;
  return n;
}

// Awaiting a non-thenable passes the value through; a wrong annotation reports.
declare const v: { a: number };
export async function h() {
  const s: string = await v;
  return s;
}
