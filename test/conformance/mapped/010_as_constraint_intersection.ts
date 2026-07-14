// `keyof T & string` in the CONSTRAINT position (the string-key filter idiom)
// must materialize the remapped keys, not collapse to `{}`. Regression for the
// M17.4 false-positive: ztsc previously emitted a spurious TS2353 on the object
// literal and TS2339 on every remapped-key access.
type Getters<T> = { [K in keyof T & string as `get_${K}`]: () => T[K] };
interface Point { x: number; y: number; }
type PG = Getters<Point>;
const g: PG = { get_x: () => 1, get_y: () => 2 }; // clean — keys exist
const n: number = g.get_x();                      // clean — remapped access
const bad: PG = { get_x: () => "no", get_y: () => 2 }; // TS2322 wrong value
const gone = g.x;                                 // TS2339 original key filtered
