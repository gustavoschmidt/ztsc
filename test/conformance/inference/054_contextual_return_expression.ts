// The contextual signature of a function supplies the contextual type of its
// RETURN expressions, not just of its parameters. `signatureOfProtoCtx` already
// used it to infer the return type, but the body walk then re-checked the same
// expressions context-free — so anything nested inside a returned object
// literal (a handler, a callback, a union-typed slot) lost its contextual type
// and its parameters went implicit-`any`.
declare function use(x: unknown): void;

interface Act {
  perform: (a: number, b: string) => void;
  keyTest?: (e: number, f: string) => boolean;
  // A union whose single callable constituent is the contextual signature.
  icon?: string | ((g: number, h: string) => string);
}
type Creator = (n: number) => Act;

// Concise body: the parenthesized object literal is contextually typed.
const a: Creator = (n) => ({
  perform: (x, y) => {
    const p: number = x;
    const q: string = y;
    use(p);
    use(q);
  },
  keyTest: (e, f) => true,
  icon: (g, h) => "s",
});

// Block body: the `return` expression is contextually typed the same way.
const b: Creator = (n) => {
  return {
    perform: (x, y) => {
      const p: number = x;
      use(p);
    },
    keyTest: (e, f) => f.length > e,
    icon: (g, h) => h,
  };
};

// Async: the payload of the contextual `Promise<Act>` is what types the body.
type AsyncCreator = (n: number) => Promise<Act>;
const c: AsyncCreator = async (n) => ({
  perform: (x, y) => use(x + y.length),
});

// The context really flows: each parameter has its contextual type, so a wrong
// use of one is an error inside the body.
const d: Creator = (n) => ({
  perform: (x, y) => {
    const wrong: string = x;
    use(wrong);
  },
});

// The same through the union-typed slot.
const e: Creator = (n) => ({
  perform: (x, y) => use(x),
  icon: (g, h) => {
    const wrong: string = g;
    return wrong;
  },
});

// A written return annotation still wins over the contextual one.
const f: Creator = (n): Act => ({
  perform: (x, y) => {
    const p: number = x;
    use(p);
  },
});

export { a, b, c, d, e, f };
