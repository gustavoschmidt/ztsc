// Inference through an INTERSECTION argument: tsc reduces an intersection
// source to its apparent members, so the constituent that structurally
// matches the generic parameter supplies the candidates and the companion
// constituent is simply skipped. The jotai `useAtom(atom(null))` shape.
interface Atom<V> {
  read: () => V;
}
interface WritableAtom<V, A extends unknown[], R> extends Atom<V> {
  write: (...a: A) => R;
}
type PrimitiveAtom<V> = WritableAtom<V, [V], void>;
type WithInit<V> = { init: V };

declare function useA<V, A extends unknown[], R>(a: WritableAtom<V, A, R>): V;

declare const p1: PrimitiveAtom<string | null>;
export const z1: string | null = useA(p1);

declare const p2: PrimitiveAtom<string | null> & WithInit<string | null>;
export const z2: string | null = useA(p2);
// The companion constituent must not pollute the inference either.
export const z2bad: number = useA(p2);

// Same through a plain (non-generic-alias) intersection whose first member
// is the matching generic instance.
interface Box<T> {
  value: T;
}
declare function unbox<T>(b: Box<T>): T;
declare const b1: Box<number> & { extra: string };
export const n1: number = unbox(b1);
export const n1bad: string = unbox(b1);

// A callable-interface parameter against an intersection carrying the
// function constituent.
interface Handler<E> {
  (e: E): void;
}
declare function on<E>(h: Handler<E>): E;
declare const h1: Handler<boolean> & { id: string };
export const bl: boolean = on(h1);
