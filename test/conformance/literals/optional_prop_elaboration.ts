// The object-literal elaboration re-judges each written property against the
// target's member. An OPTIONAL member accepts `undefined` — the `| undefined`
// the structural relation folds in before it compares — so the elaboration has
// to fold it in too. Otherwise every optional property fed a `T | undefined`
// value is blamed for a failure that happened somewhere else in the literal.
// immich's `getEnv(): EnvData` is that shape: one property really does not fit
// and three `?`-declared ones took the blame.

interface Target {
  host?: string;
  port: number;
  level?: 'a' | 'b';
  nested: { tag?: string; id: number };
}

declare const src: {
  HOST: string | undefined;
  LEVEL: 'a' | 'b' | undefined;
  TAG: string | undefined;
  PORT: string;
};

// The only real mismatch is `port`; the three optional properties are fine.
const bad: Target = {
  host: src.HOST,
  port: src.PORT, // TS2322
  level: src.LEVEL,
  nested: { tag: src.TAG, id: 1 },
};

// Same through a return position.
const f = (): Target => {
  return {
    host: src.HOST,
    port: src.PORT, // TS2322
    level: src.LEVEL,
    nested: { tag: src.TAG, id: 1 },
  };
};

// With nothing wrong, nothing is reported at all.
const ok: Target = {
  host: src.HOST,
  port: 1,
  level: src.LEVEL,
  nested: { tag: src.TAG, id: 1 },
};

// An optional property fed a genuinely wrong type is still reported.
const alsoBad: Target = {
  host: 1, // TS2322
  port: 1,
  nested: { id: 1 },
};

// Union target: the same rule on the constituent the literal is judged against.
interface Other {
  kind: 'other';
  port: number;
}
const u: Target | Other = {
  host: src.HOST,
  port: src.PORT, // TS2322
  nested: { id: 1 },
};

export { alsoBad, bad, f, ok, u };
