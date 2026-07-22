// TS2359 gate: the RHS of `instanceof` is legal iff it is `any` or assignable
// to `Function` — which includes any type carrying a call OR construct
// signature. A value typed as a constructor interface (the shape of the
// `Error`/`RegExp` globals: `interface XConstructor { new(): X }; var X: XConstructor`)
// is a legal RHS even though it is an object, not a class value. A plain
// object with no signatures is rejected.

interface MyErr {
  message: string;
}
interface MyErrCtor {
  new (m?: string): MyErr;
}
declare const MyError: MyErrCtor;

declare const fn: (x: number) => number;

const plain = { a: 1 };

function f(x: unknown): void {
  const a = x instanceof MyError; // ok — construct signature
  const b = x instanceof fn; // ok — call signature
  const c = x instanceof plain; // TS2359 — no call/construct signature
  void a;
  void b;
  void c;
}
