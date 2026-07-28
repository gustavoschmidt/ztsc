// A NON-homomorphic mapped type applied to a generic (`Pick`/`Omit`/`Record`
// over a type parameter) defers on its CONSTRAINT, not on a source, so the
// homomorphic apparent-type route could not reach it and it exposed no members
// at all. Its apparent type is the base constraint of the whole map:
// `Omit<Partial<T>, "id">` with `T extends Base` has apparent type
// `Omit<Partial<Base>, "id">`. Distilled from excalidraw's `mutateElement`.
type El = {
  id: string;
  version: number;
  x: number;
  y: number;
  width: number;
  height: number;
};

type Updates<T extends El> = Omit<Partial<T>, "id" | "version">;

export const move = <T extends El>(element: T, updates: Updates<T>) => {
  const x = updates.x ?? element.x;
  const y = updates.y ?? element.y;
  const sized = typeof updates.width !== "undefined";
  return [x, y, sized] as const;
};

// negative control: a key that is NOT in the base constraint is still missing.
export const bad = <T extends El>(updates: Updates<T>) => updates.nope; // TS2339

// negative control: a key the `Omit` removed is still missing.
export const omitted = <T extends El>(updates: Updates<T>) => updates.id; // TS2339

// Pick over a generic behaves the same way.
type Two<T extends El> = Pick<T, "x" | "y">;
export const pick = <T extends El>(p: Two<T>) => [p.x, p.y];
export const pickBad = <T extends El>(p: Two<T>) => p.width; // TS2339
