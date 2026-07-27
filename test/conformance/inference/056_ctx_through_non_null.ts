// A non-null assertion is transparent to contextual typing: the operand sees
// the assertion's own contextual type. Decisive when the callee's type
// parameter appears only in its RETURN type (the `querySelector<E extends
// Element = Element>` shape) — without the context it falls back to the
// default and every use is rejected.
interface El {
  tag: string;
}
interface HEl extends El {
  h: number;
}

declare function q<E extends El = El>(s: string): E | null;
declare function take(el: HEl): void;

// baseline: the context reaches the call directly
const a1: HEl | null = q("a");

// through the assertion — variable target
const a2: HEl = q("b")!;

// through the assertion — argument target
take(q("c")!);

// nested assertions stay transparent
const a3: HEl = q("d")!!;

// negative: an unrelated target still fails (the default is not silently kept)
interface Other {
  o: number;
}
const a4: Other = q("e")!;

// negative: the assertion still strips null, it does not add it
const a5: HEl | null = q("f")!;
const a6: null = q("g")!;

export { a1, a2, a3, a4, a5, a6 };
