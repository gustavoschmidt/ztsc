// A `Pick`-style map (`{ [P in K]: T[P] }`, K extends keyof T) is not
// syntactically homomorphic, yet must copy the source's optional modifier from
// the `T[P]` modifiers type. ztsc previously dropped it, wrongly requiring the
// optional member (spurious TS2741 on the clean lines).
type MyPick<T, K extends keyof T> = { [P in K]: T[P] };
interface Src { req: string; opt?: number; }
type P = MyPick<Src, "req" | "opt">;
const ok1: P = { req: "x" };
const ok2: P = { req: "x", opt: 3 };
const miss: P = { opt: 3 };
