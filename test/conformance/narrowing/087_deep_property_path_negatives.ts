// Tracking a deeper path must not narrow a DIFFERENT reference, and must be
// dropped when a prefix of the path is written.
declare function f(i: number): void;
type Deep = { a: { b: { c: { d: number | null } } } };
declare const o: Deep;
declare const p: Deep;

// A guard on one path says nothing about another.
export const g = () => {
  if (o.a.b.c.d) {
    f(p.a.b.c.d);
  }
};

// A sibling link at the last step is a different reference too.
declare const q: { a: { b: { c: { d: number | null; e: number | null } } } };
export const h = () => {
  if (q.a.b.c.d) {
    f(q.a.b.c.e);
  }
};

// Writing the root invalidates the narrowing.
declare let r: Deep;
export const i = () => {
  if (r.a.b.c.d) {
    r = p;
    f(r.a.b.c.d);
  }
};

// So does writing an interior prefix of the deep path.
declare const s: { a: { b: { c: { d: number | null } } } };
export const k = () => {
  if (s.a.b.c.d) {
    s.a.b = p.a.b;
    f(s.a.b.c.d);
  }
};
