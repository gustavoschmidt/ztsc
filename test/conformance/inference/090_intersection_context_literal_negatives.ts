// Negatives for 089: keeping the literal must not make a WRONG literal fit,
// and an intersection whose members admit no literal still widens.

interface Settings {
  leading?: boolean;
  trailing?: boolean;
}

type Isect = Settings & { leading: true };

// The kept literal is `false`, and `false` is not `true`.
export const a: Isect = { leading: false }; // TS2322

// No member of the intersection is literal-like, so the property widens as
// before and a widened value is accepted.
type Wide = Settings & { extra: string };
export const b: Wide = { leading: true, extra: "s" };
export const c = { leading: true } as const;
export const d: Settings = c;
