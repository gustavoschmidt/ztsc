// An `infer` binder declared inside a MAPPED TYPE's key set is a binder of the
// enclosing conditional: `Record<infer K, V>` is `{ [P in K]: V }`, so `K` has
// to be collected and matched there, not only in the arms that walk objects,
// refs and unions. Missed, the conditional bound nothing and related its check
// type against an extends clause still holding a raw `infer` var — which
// relates to nothing, so it always took the FALSE branch.

type AnyListener = (...args: any[]) => any;

type EventName<M> = M extends Record<infer N extends keyof M, AnyListener>
  ? N
  : never;

type Events = {
  statusChange: (evt: { status: string }) => void;
  timeUpdate: (evt: { t: number }) => void;
};

export const a: EventName<Events> = "statusChange";
export const b: EventName<Events> = "timeUpdate";

// NEGATIVE: the true branch really is the key union, not `string`.
export const c: EventName<Events> = "notAnEvent";

// The same binder reached as a type-parameter CONSTRAINT at a call site.
declare function on<M extends Record<string, AnyListener>, N extends EventName<M>>(
  map: M,
  name: N,
): void;
declare const ev: Events;
on(ev, "timeUpdate");

// NEGATIVE: a name the map does not declare.
on(ev, "nope");

// The mapped type's VALUE is an inference position too, when the key set is
// what defers the map.
type ValueOf<M> = M extends Record<infer _K, infer V> ? V : never;
export const v: ValueOf<{ a: number; b: number }> = 1;

// NEGATIVE: the value union is `number`, not `string`.
export const w: ValueOf<{ a: number; b: number }> = "s";

// An unconstrained binder in the key set still names the keys.
type Keys<M> = M extends Record<infer K, any> ? K : never;
export const k: Keys<{ x: 1; y: 2 }> = "y";
