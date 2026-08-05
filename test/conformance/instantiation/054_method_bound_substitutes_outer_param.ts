// A generic interface's METHOD may constrain its own type parameter with a
// type built out of the INTERFACE's parameter. Instantiating the interface has
// to substitute that bound: leaving it standing over a parameter that has just
// been substituted away produces a constraint nothing can satisfy.
//
// ztsc gated the substitution on `higherOrderSigEligible`, which only decides
// whether a rewritten bound is safe to ENFORCE. A bound it declines — one whose
// alias chain has an `infer` in an `extends` clause, so `boundReducible` is
// false — was left alone entirely, and the call was then clamped to it.
// socket.io writes exactly that: `emit<Ev extends EventNames<Remove
// Acknowledgements<E>>>` on `StrictEventEmitter<…, E>`, where the bound runs
// through `Last<Parameters<…>>`.

type Params<T extends (...args: any) => any> = T extends (...args: infer P) => any ? P : never;

interface EventsMap {
  [event: string]: any;
}
interface DefaultEventsMap {
  [event: string]: (...args: any[]) => void;
}

type EventNames<Map extends EventsMap> = keyof Map & (string | symbol);
type IsAny<T> = 0 extends 1 & T ? true : false;
type IfAny<T, A = true, B = false> = IsAny<T> extends true ? A : B;
type Last<V extends readonly unknown[]> = V extends readonly [infer E]
  ? E
  : V extends readonly [infer _, ...infer Tail]
    ? Last<Tail>
    : V extends ReadonlyArray<infer E>
      ? E
      : never;
type WithoutAck<Map extends EventsMap, K extends EventNames<Map> = EventNames<Map>> = IfAny<
  Last<Params<Map[K]>> | Map[K],
  K,
  never
>;
type Remove<E extends EventsMap> = { [K in WithoutAck<E>]: E[K] };

// The bound goes through the mapped type.
interface Emitter<E extends EventsMap> {
  emit<Ev extends EventNames<Remove<E>>>(ev: Ev): void;
}
declare const e1: Emitter<DefaultEventsMap>;
e1.emit('AppRestartV1');

// The bound is the conditional alias itself.
interface Emitter2<E extends EventsMap> {
  emit<Ev extends WithoutAck<E>>(ev: Ev): void;
}
declare const e2: Emitter2<DefaultEventsMap>;
e2.emit('AppRestartV1');

// The same through a class, its type argument coming from a DEFAULT, and the
// method inherited from a base whose argument is itself computed.
declare class Base<E extends EventsMap> {
  emit<Ev extends EventNames<E>>(ev: Ev): void;
}
declare class Derived<L extends EventsMap = DefaultEventsMap, E extends EventsMap = L> extends Base<Remove<E>> {
  readonly tag: 1;
}
declare const d: Derived;
d.emit('AppRestartV1');

// `keyof` alone over the mapped alias.
interface Emitter3<E extends EventsMap> {
  emit<Ev extends keyof Remove<E>>(ev: Ev): void;
}
declare const e3: Emitter3<DefaultEventsMap>;
e3.emit('AppRestartV1');

export {};
