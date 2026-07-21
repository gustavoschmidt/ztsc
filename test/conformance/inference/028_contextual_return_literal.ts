// Contextual return-type threading for un-annotated function expressions.
// When an arrow with no return annotation is checked against a contextual
// signature, that signature's RETURN type contextually types the body's
// return expressions, so object literals keep the literal discriminants the
// context expects instead of widening (`type: 'poly'` stays `"poly"`).
interface Poly {
  type: 'poly';
  coords: number[][];
}

// (1) direct annotation, block body
const cb1: (c: number[][]) => Poly = (coords) => {
  return { type: 'poly', coords };
};
// (2) direct annotation, expression body
const cb2: (c: number[][]) => Poly = (coords) => ({ type: 'poly', coords });

// (3) argument position (callback parameter)
declare function run(fn: (c: number[][]) => Poly): void;
run((coords) => ({ type: 'poly', coords }));

// (4) property position (object member signature)
interface Holder {
  make: (c: number[][]) => Poly;
}
const h: Holder = { make: (coords) => ({ type: 'poly', coords }) };

// (5) union-typed contextual return distributes
const cb5: (c: number[][]) => Poly | null = (coords) =>
  coords.length ? { type: 'poly', coords } : null;

// (6) `.map<U>(cb: (…) => U): U[]` with U fixed by the outer return
// annotation `Poly[]` (return-type-priority inference), then threaded into
// the callback body so `{ type: 'poly' }` keeps its literal.
declare const rows: number[][][];
function f6(): Poly[] {
  return rows.map((coords) => ({ type: 'poly', coords }));
}
function f7(): Poly[] {
  return rows.map((coords) => {
    return { type: 'poly', coords };
  });
}

// (7) context property is `string`: widening is correct, no error.
interface StrHolder {
  t: string;
}
const sh: (n: number) => StrHolder = () => ({ t: 'anything' });

// (8) async arrow: the awaited contextual return types the body's returns.
const cb8: (c: number[][]) => Promise<Poly> = async (coords) => ({ type: 'poly', coords });

// (9) NEGATIVE control: no context — the map element widens to `string`, so
// reading `.type` as the literal `'poly'` is an error (TS2322).
const arr = rows.map((coords) => ({ type: 'poly', coords }));
const bad: 'poly' = arr[0].type;
