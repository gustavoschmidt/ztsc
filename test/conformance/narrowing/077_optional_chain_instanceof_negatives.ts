// Negatives: only the TRUE branch of an optional-chain `instanceof` says the
// receivers are non-nullish, and the rule asserts nothing beyond that.
type Img = { width: number };
declare const m: Map<string, { image: Promise<void> | Img }>;

// false branch: the chain may well have short-circuited
export const a = async () => {
  const cached = m.get("x");
  if (!(cached?.image instanceof Promise)) {
    await cached.image; // error: 'cached' is possibly 'undefined'
  }
};

// the receiver is non-nullish, but the PROPERTY keeps its own type outside the
// narrowed reference
export const b = () => {
  const cached = m.get("x");
  if (cached?.image instanceof Promise) {
    const img: Img = cached.image; // error: narrowed to Promise
    return img;
  }
  return null;
};

// a plain (non-optional) receiver is not asserted by this rule either way
export const c = (v: { image: Promise<void> } | undefined) => {
  if (v!.image instanceof Promise) {
    return 1;
  }
  return v.image; // error: 'v' is possibly 'undefined'
};
