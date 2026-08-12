// Bivariant parameter comparison is decided by the TARGET's declaration kind
// alone (tsc's `compareSignaturesRelated` reads `target.declaration.kind`).
// A class METHOD assigned to a function-typed PROPERTY therefore relates its
// parameters CONTRAVARIANTLY, and only a method TARGET is bivariant.
type Opts = { a: number };

declare class S1 {
  post(path: string, opts?: Opts): void;
  post(path: string, user: number, opts?: Opts): void;
}
declare class S2 {
  post(path: string, opts?: Opts): void;
}
declare const s1: S1;
declare const s2: S2;

// property target: strict, both directions report
declare let pt: { post: (path: string, opts: unknown) => void };
pt = s1;
pt = s2;
declare function takeProp(x: { post: (path: string, opts: unknown) => void }): void;
takeProp(s1);
takeProp(s2);

// method target: bivariant, no error
declare let mt: { post(path: string, opts: unknown): void };
mt = s1;
mt = s2;

// plain contravariance controls
declare let g: (x: unknown) => void;
declare const f: (x: Opts | undefined) => void;
g = f;
declare let hp: { h: (x: Opts) => void };
declare const hq: { h: (x: unknown) => void };
hp = hq;

export { pt, mt, g, hp };
