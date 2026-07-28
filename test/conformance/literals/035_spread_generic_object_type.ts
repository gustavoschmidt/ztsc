// A spread whose source is a GENERIC object type — a still-deferred mapped
// type, indexed access or conditional — yields an INTERSECTION, exactly as it
// already did for a bare type parameter. Flattening it copied no members at
// all, so the literal lost everything the spread carried.
interface Base {
  id: string;
  version: number;
  x: number;
  y: number;
  width: number;
  height: number;
}
type Upd<T extends Base> = Omit<Partial<T>, "id" | "version">;

export const f = <T extends Base>(updates: Upd<T>) => {
  const a: Upd<T> = { ...updates, x: 3 };
  const b: Upd<T> = { ...updates };
  return [a, b];
};

export const g = <T extends Base>(p: Partial<T>) => {
  const a: Partial<T> = { ...p, y: 1 };
  return a;
};

export const h = <T extends Base, K extends keyof T>(v: T[K], rest: Pick<T, K>) => {
  const a: Pick<T, K> = { ...rest };
  void v;
  return a;
};

// NEGATIVE: without the generic spread there is no intersection to carry the
// relation, and a plain literal does not satisfy a deferred mapped type.
export const bad = <T extends Base>() => {
  const a: Upd<T> = { x: 3 };
  const b: Partial<T> = { y: 1 };
  return [a, b];
};

// The intersection really is the type: the spread's own members survive.
export const keep = <T extends Base>(updates: Upd<T>) => {
  const a = { ...updates, tag: 1 as const };
  const t: 1 = a.tag;
  void t;
  return a;
};
