// A deferred mapped alias used generically (passthrough) and at a concrete
// instantiation. While `T` is unbound the mapped type stays deferred; the
// wrapper resolves it only when `T` is supplied.
type MyPartial<T> = { [K in keyof T]?: T[K] };
type Wrap<T> = MyPartial<T>;

interface Foo { x: number; y: string; }
declare const w: Wrap<Foo>;
const wx: number | undefined = w.x;
const bad: number = w.x; // TS2322

// Nested generic use.
type Box<T> = { value: MyPartial<T> };
declare const bx: Box<Foo>;
const bvx: number | undefined = bx.value.x;
