// A conditional whose CHECK is an interface/class reference carrying free type
// params has a fixed member-name set, so `extends` targets that are decided by
// shape alone resolve instead of deferring. This is immer's `Draft<State<T,E>>`
// reduced to its skeleton: the map/set/weak-ref arms are all "definitely not",
// and the array arm (`T extends any[]`) is too, so the chain reaches its object
// arm and the state's own members stay visible.

interface State<T, E> {
  data: T;
  status: string;
  error: E | null;
}

interface Boxy {
  unwrap(): number;
}

class Holder<T> {
  value: T = null as unknown as T;
}

type Writable<T> = { -readonly [K in keyof T]: T[K] };

type Draftish<T> = T extends Boxy
  ? number
  : T extends any[]
    ? string
    : T extends readonly [number, number]
      ? boolean
      : T extends object
        ? Writable<T>
        : T;

export function readsState<T, E>(s: Draftish<State<T, E>>) {
  s.status = 'x';
  s.error = null;
  return s.data;
}

export function readsClass<T>(h: Draftish<Holder<T>>) {
  return h.value;
}

// Negatives: the resolved shape is still checked — an absent member is an
// error, and the object arm's members are the interface's, not the array's.
export function absentMember<T, E>(s: Draftish<State<T, E>>) {
  return s.missing;
}

export function notAnArray<T, E>(s: Draftish<State<T, E>>) {
  return s.length;
}
