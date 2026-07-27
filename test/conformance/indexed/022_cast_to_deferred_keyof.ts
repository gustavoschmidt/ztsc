// The `as`-cast overlap test (TS2352) uses tsc's *comparable* relation, and a
// deferred `keyof T` relates through the key domain `string | number | symbol`
// (tsc's `keyofConstraintType`) — never through `keyof <constraint>`. The
// comparable relation then distributes over that union existentially, so the
// standard `Object.keys(o).forEach((k) => o[k as keyof T])` idiom is legal.
declare const s: string;
declare const n: number;
declare const sym: symbol;

export function viaObject<T extends object>(o: T) {
  return Object.keys(o).map((k) => o[k as keyof T]);
}

export function unconstrained<T>() {
  return s as keyof T;
}
export function constrainedShape<T extends { x: 1 }>() {
  return s as keyof T;
}
export function numberKey<T extends object>() {
  return n as keyof T;
}
export function symbolKey<T extends object>() {
  return sym as keyof T;
}

// a parameter constrained BY a deferred keyof resolves the same way
export function viaKeyParam<T, K extends keyof T>() {
  return s as K;
}

// a concrete keyof is a literal union and needs no special treatment
export const concrete = s as keyof { x: 1; y: 2 };
