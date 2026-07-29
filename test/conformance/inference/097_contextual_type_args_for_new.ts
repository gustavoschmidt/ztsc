// A class-value `new` takes its type arguments from the CONTEXTUAL type too,
// matched against the instance type — tsc's return-type inference pass. Without
// it `new Box(1)` under a `Box<string>` context was a `Box<unknown>` and the
// assignment failed.

declare class CtxBox<T> {
  constructor(a?: number);
  v: T;
  read(): T;
}

const ctxAnn: CtxBox<string> = new CtxBox(1);

function ctxReturn(): CtxBox<string> {
  return new CtxBox(1);
}

// Through a structurally-related contextual type, not just the same class.
interface CtxReader<T> {
  read(): T;
}
const ctxIface: CtxReader<string> = new CtxBox(1);

// An ARGUMENT still wins over the contextual type.
declare class CtxPair<T> {
  constructor(a: T);
  v: T;
}
const ctxArg: CtxPair<string | number> = new CtxPair(1);

// An explicit type argument still wins over both.
const ctxExplicit: CtxReader<number> = new CtxBox<number>(1);

// Nothing to go on: the parameter keeps its own fallback.
const ctxNone = new CtxBox(1);
const ctxNoneRead: unknown = ctxNone.read();
