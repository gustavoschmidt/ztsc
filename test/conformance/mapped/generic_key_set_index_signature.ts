// A still-generic mapped type is not memberless. tsc's
// `resolveMappedTypeMembers` runs `forEachType(getLowerBoundOfKeyType(K),
// addMemberForKeyType)`, and `getLowerBoundOfKeyType` reduces `keyof T` to
// `getIndexType(getApparentType(T))` — so a key type that is not a literal name
// becomes an INDEX SIGNATURE of the template. Under `T extends Record<string,
// any>`, `Record<keyof T, V>` really does have `[x: string]: V`.
//
// ztsc left such a type opaque, so neither `inferFromIndexTypes` nor the
// relation had anything to pair a `{[s: string]: V}` target with. social-app's
// router is the shape: `constructor(description: Record<keyof T, string |
// string[]>)` then `Object.entries(description)` — the call fell to the
// `entries(o: {}): [string, any][]` overload, `pattern` came back `any`, and
// `pattern.forEach(subPattern => …)` reported TS7006 on `subPattern`.
declare function takesIndex<V>(o: { [k: string]: V }): V;

export function p1<T extends Record<string, any>>(
  d: Record<keyof T, string | string[]>,
) {
  // Inference through the apparent index signature…
  const v = takesIndex(d);
  const bad1: number = v;

  // …and the relation that has to accept the argument in the first place.
  const idx: { [k: string]: string | string[] } = d;
  const bad2: { [k: string]: number } = d;

  // The lib overload this all exists for.
  const entries = Object.entries(d);
  const bad3: number = entries;

  // The class's own narrowing still works off it.
  for (const [, pattern] of entries) {
    if (typeof pattern === 'string') {
      const s: number = pattern;
      void s;
    } else {
      pattern.forEach(subPattern => {
        const t: number = subPattern;
        void t;
      });
    }
  }
  return [bad1, bad2, bad3, idx];
}

// The inline spelling behaves the same.
export function p2<T extends Record<string, any>>(d: {
  [P in keyof T]: number;
}) {
  const v = takesIndex(d);
  const bad: string = v;
  return bad;
}

// A LITERAL key set materializes as properties, not an index signature, so it
// is not related to a bare index target (a required-property target still
// rejects a deferred map either way).
export function p3<T extends { a: 1 }>(d: Record<'x' | 'y', string>) {
  const idx: { [k: string]: string } = d;
  return [idx, null as unknown as T];
}

// (A target that NAMES a required member is still rejected — the apparent
// index signature is not a property. Not pinned here: ztsc reports that
// rejection as TS2322 where tsc reports TS2741, a pre-existing message
// divergence on the deferred-map source path this change does not touch.)
