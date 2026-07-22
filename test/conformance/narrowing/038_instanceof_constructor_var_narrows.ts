// `instanceof` against a lib-style constructor narrows the true branch even
// though the RHS is `interface FooConstructor` + `declare var Foo` (an object
// carrying construct signatures), NOT a `class` value. tsc's getInstanceType
// takes the `prototype` property type, else the construct-signature return
// type. Before the fix these true-branch member accesses all reported TS2339
// on `unknown`; after it they are clean (this whole case is zero-error).

interface MyErr {
  message: string;
}
interface MyErrCtor {
  new (m?: string): MyErr;
  readonly prototype: MyErr;
}
declare const MyError: MyErrCtor;

function libCtors(e: unknown): void {
  if (e instanceof Error) {
    e.message; // narrowed to Error
  }
  if (e instanceof Array) {
    e.length; // narrowed to any[]
  }
  if (e instanceof Date) {
    e.getTime(); // narrowed to Date
  }
  if (e instanceof RegExp) {
    e.test("x"); // narrowed to RegExp
  }
}

function interfaceCtor(x: unknown): void {
  if (x instanceof MyError) {
    x.message; // narrowed via prototype/construct-sig return
  }
}
