// An INTERSECTION contextual type must still supply contextual parameter
// types. tsc's `getSignaturesOfType` concatenates an intersection's
// constituents' call signatures and `getContextualCallSignature` either takes
// the sole one or COMBINES them (`getIntersectedSignatures`), unioning the
// parameter types position-wise.

type A = { onToggle?: (open: boolean) => void };
type B = { onToggle?: (ev: { t: string }) => void; other?: number };

declare function take(p: A & B): void;
take({
  onToggle: (open) => {
    // `open` is `boolean | { t: string }` — usable, not an implicit any.
    if (open) {
      return;
    }
  },
});

// Only one constituent is callable: that signature answers alone.
type C = { cb?: (n: number) => void };
type D = { other?: string };
declare function take2(p: C & D): void;
take2({ cb: (n) => n.toFixed(2) });

// A bare intersection-of-signatures annotation.
declare const f: ((open: boolean) => void) & ((ev: { t: string }) => void);
export const g: typeof f = (x) => {
  if (x) {
    return;
  }
};

// Differing arity: a parameter only some constituents declare is optional, so
// an arrow that takes just the common prefix is contextually typed.
declare function take5(p: {
  h?: ((a: number) => void) & ((a: number, b: string) => void);
}): void;
take5({ h: (a) => a.toFixed(2) });

// An optional PROPERTY whose type is an intersection of callables arrives as
// `(A & B) | undefined`.
type E = { onX?: ((n: number) => void) & ((s: string) => void) };
declare function take3(p: E): void;
take3({ onX: (v) => { if (v) return; } });

// Control: a plain (non-intersection) contextual type is unchanged.
declare function take4(p: A): void;
take4({ onToggle: (open) => { if (open) return; } });
