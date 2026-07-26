declare const a: number;
declare const b: number;
declare const c: number;

// Negative: an identifier after the closing `>` can start an expression, so
// this stays two relational comparisons — `(a < b) > c` — not an
// instantiation expression.
const chained = a < b > c;
const plain: boolean = a < b;
