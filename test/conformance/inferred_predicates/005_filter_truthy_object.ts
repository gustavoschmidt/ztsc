// `!!x` on an object|null element: no falsy overlap, so it synthesizes.
interface Foo { a: number; }
const xs: (Foo | null)[] = [{ a: 1 }, null];
const ys = xs.filter((x) => !!x);
const f: Foo[] = ys;
