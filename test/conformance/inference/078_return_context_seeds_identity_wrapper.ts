// An identity wrapper (`wrap<F>(f: F): F`) gets its type parameter from the
// call's contextual RETURN type, before the argument is contextually typed —
// otherwise `F` is still `any` while the arrow is checked and every one of its
// parameters is an implicit `any`.
type Fn = (files: string[], flag: boolean) => void;

declare const wrap: <F extends (...a: any[]) => void>(f: F) => F;
export const a: Fn = wrap((files, flag) => {
  files.length;
  const bad: number = flag; // TS2322 — `flag` is boolean, not any
  void bad;
});

// unconstrained too
declare const wrap2: <F>(f: F) => F;
export const b: Fn = wrap2((files, flag) => {
  files.length;
  const bad2: number = flag; // TS2322
  void bad2;
});

// a conditional parameter type still receives the seeded argument type
declare const wrap3: <F extends (...a: any[]) => void>(
  f: [F] extends [never] ? never : F,
) => F;
export const c: Fn = wrap3((files, flag) => {
  files.length;
  void flag;
});

// a WRAPPED return (`U[]`, the map/flatMap shape) is deliberately not seeded
// this way — the callback-return rule already covers it and nothing changes
declare function mapAll<U>(cb: (x: number) => U): U[];
const r: string[] = mapAll((x) => `${x}`);
void r;

// no contextual return type: the argument keeps its context-free check
export const d = wrap((files: string[]) => {
  void files;
});
