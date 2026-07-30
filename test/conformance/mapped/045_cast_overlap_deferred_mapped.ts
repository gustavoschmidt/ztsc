// The cast-overlap test (TS2352) against a still-GENERIC mapped type. Such a
// type's member set is unknown until it is instantiated, so no member-based
// verdict is available and tsc's comparable relation lets the cast through —
// this is redux-toolkit's `slice as Omit<typeof slice, 'actions'> & { actions:
// { success: … } }`, where the slice's own `actions` is a mapped type over
// `keyof Reducers`.

interface Sl<S, R> {
  name: string;
  reducer: (s: S) => S;
  actions: { [K in keyof R]: (p?: unknown) => void };
  caseReducers: R;
}

type Made<P> = { (p: P): void; type: string };

export function generic<T, R extends { [k: string]: (s: { data: T }) => void }>(
  s: Sl<{ data: T }, R>,
) {
  // The replacement `actions` names one key the generic mapped type may or may
  // not have; the cast is legal either way.
  return s as Omit<typeof s, 'actions'> & { actions: { success: Made<T> } };
}

export function genericBothMapped<T, R extends { [k: string]: (s: { data: T }) => void }>(
  s: Sl<{ data: T }, R>,
) {
  return s as Omit<typeof s, 'actions'> & {
    actions: { [K in keyof typeof s.actions]: Made<unknown> } & { success: Made<T> };
  };
}

// Negatives: the concession is scoped to an OBJECT-shaped counterpart. A
// mapped type is an object type whatever its keys are, so a primitive target
// is still rejected — and a cast whose target simply lacks a required member
// of the source is still rejected too.
export function toPrimitive<T extends { [K in keyof T]: number }>(v: T) {
  return v as string; // TS2352
}

export function missingMember<T, R extends { [k: string]: (s: { data: T }) => void }>(
  s: Sl<{ data: T }, R>,
) {
  return s as Omit<typeof s, 'actions'> & { extra: number }; // TS2352
}
