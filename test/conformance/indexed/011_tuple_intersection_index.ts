// Indexing an intersection of a tuple and an object by a concrete string key
// resolves to the object constituent's member — even when a tuple element
// carries a generic call signature. A deeply-nested type variable inside a
// tuple element must NOT make the whole intersection a "generic object type"
// and strand the access as an unreduced `T[K]` (tsc's `isGenericObjectType`
// is shallow: only a top-level instantiable constituent defers).

interface Fancy<A extends string, B extends object> {
  <K extends A>(...args: [key: K, opts?: B] | [key: string, def: string]): string;
  brand: A;
}
interface Info {
  language: string;
}

type Bundle<A extends string, B extends object> = [
  t: Fancy<A, B>,
  info: Info,
  ready: boolean,
] & { t: Fancy<A, B>; info: Info; ready: boolean };

declare function make(): Bundle<"ns", {}>;

// Indexed-access TYPE by a concrete key -> the object member type, NOT the
// whole intersection (the previous bug left this as `Bundle[...]` unreduced,
// so `.language` below reported TS2339).
function useInfo(info: ReturnType<typeof make>["info"]): string {
  return info.language;
}
type TOf = Bundle<"ns", {}>["t"];
const tt: TOf = make().t;

// Member access on the intersection VALUE reaches the object members ...
const b = make();
const bt = b.t;
const bi = b.info;
const br = b.ready;
// ... and the tuple constituent (numeric index, length, array method).
const e0 = b[0];
const e1 = b[1];
const len: number = b.length;
const mapped = b.map((x) => x);

// Negative control: a key on NEITHER constituent still errors.
const bad = b.nope; // TS2339

// Negative control: a bare type-variable CONSTITUENT keeps the access
// deferred, so the intersected member is refined per instantiation instead of
// being eagerly (and wrongly) resolved to the non-generic side.
type MergeA<T extends { a: unknown }> = ({ a: number } & T)["a"];
type M1 = MergeA<{ a: 1 }>;
const m1: 1 = null as any as M1; // ok only if refined to `1` (deferred), not `number`
