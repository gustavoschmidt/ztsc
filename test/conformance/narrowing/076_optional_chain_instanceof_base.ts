// `a?.b instanceof C` being true implies the chain did not short-circuit, so
// its receivers are known non-nullish in the true branch — the same
// optional-chain containment rule truthiness narrowing already applies.
type Img = { width: number };
declare const m: Map<string, { image: Promise<void> | Img }>;

export const a = async () => {
  const cached = m.get("x");
  if (cached?.image instanceof Promise) {
    await cached.image;
  }
};

// deeper chain: every receiver on the spine is asserted
type Node2 = { child?: { value?: Date | string } };
export const b = (n: Node2 | undefined) => {
  if (n?.child?.value instanceof Date) {
    return n.child.value.getTime();
  }
  return 0;
};

// element-access link
export const c = (xs: { v: Date | string }[] | undefined) => {
  if (xs?.[0].v instanceof Date) {
    return xs[0].v.getTime();
  }
  return 0;
};
