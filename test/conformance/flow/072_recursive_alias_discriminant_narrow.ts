// A RECURSIVE type alias is deferred as a reference rather than expanded, so
// the discriminated union it stands for used to arrive at the narrowers as a
// non-union and no narrowing was applied at all. tsc always has a real union
// here (`getDeclaredTypeOfTypeAlias`) and narrows every form below; a
// NON-recursive alias always worked, which is why the shape needs a
// self-referential union to show.
type Embed =
  | {type: 'post'; view: {a: string}}
  | {type: 'feed'; view: {b: string}}
  | {type: 'both'; view: Embed; media: Embed}
  | {type: 'none'; view: null};

// Positive equality on a NESTED reference whose declared type is the alias.
declare const e1: Embed;
if (e1.type === 'both') {
  if (e1.media.type === 'post') {
    const s: string = e1.media.view.a;
    void s;
  }
}

// Negative equality, chained in a single `&&` — social-app's `MediaPreview`
// shape, which reported TS2322 because the recursive constituent survived in
// `e.media.view`.
declare const e2: Embed;
if (e2.type === 'both' && e2.media.type !== 'both' && e2.media.view !== null) {
  const v: {a: string} | {b: string} = e2.media.view;
  void v;
}

// `switch` on the same discriminant: every case narrows, and the clause list
// is exhaustive so the function needs no trailing return.
function label(x: Embed): string {
  switch (x.type) {
    case 'post':
      return x.view.a;
    case 'feed':
      return x.view.b;
    case 'both':
      return label(x.media);
    case 'none':
      return '';
  }
}
void label;

// Truthiness on the discriminant of a recursive alias.
type Node2 = {kind: ''; next: null} | {kind: 'n'; next: Node2};
declare const n: Node2;
if (n.kind) {
  const nx: Node2 = n.next;
  void nx;
}

// A non-recursive alias behaves identically (it always did); kept so a change
// that stops resolving the deferred reference fails here too.
type Plain = {k: 'x'; v: string} | {k: 'y'; v: number};
declare const p: {t: 'has'; m: Plain} | {t: 'no'};
if (p.t === 'has' && p.m.k === 'x') {
  const s2: string = p.m.v;
  void s2;
}
