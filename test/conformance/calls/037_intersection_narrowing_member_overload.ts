// A class intersected with an object literal that re-declares one of its
// methods with a NARROWER signature: the property type is the intersection of
// the two, and the call must see both signatures. Only the second one accepts
// this listener, so resolving against the first constituent alone reported a
// spurious TS2345 on the argument.

interface EventLike {
  kind: string;
}
type Handler = ((e: EventLike) => void) | null;

declare class Emitter {
  addEventListener(type: string, callback: Handler, once?: boolean): void;
  removeEventListener(type: string, callback: Handler): void;
}

type Narrowed<T> = Emitter & {
  addEventListener: (
    type: "fulfilled",
    listener: (event: { data: { result: [number, T] } }) => void,
  ) => void;
  removeEventListener: (
    type: "fulfilled",
    listener: (event: { data: { result: [number, T] } }) => void,
  ) => void;
};

export function subscribe<T>(pool: Narrowed<T>): void {
  const listener = (event: { data: { result: void | [number, T] } }) => {
    void event;
  };
  pool.addEventListener("fulfilled", listener);
  pool.removeEventListener("fulfilled", listener);
  // The base constituent's signature is still reachable.
  pool.addEventListener("other", null);
}
