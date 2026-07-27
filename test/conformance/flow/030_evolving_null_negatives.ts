// Negatives for the evolving ("auto") variable rule: it applies only to a
// `let`/`var` with no annotation whose initializer is literally `null` or
// `undefined`. Everything else keeps a real declared type.

// Annotated: the annotation still constrains writes and reads.
let a: null = null;
a = 5;
const aa: number = a;

// `const`: not evolving, and not writable at all.
const c = null;
const cc: number = c;

// A non-nullish initializer is not evolving.
let d = 0;
d = "x";

// An initializer that is merely nullish-typed (not the literal) is not
// evolving either.
declare const maybe: null;
let e = maybe;
e = 1;

// A destructuring declarator is never evolving.
declare const src: { p: null };
let { p } = src;
p = 2;

// The declared type of an evolving variable is still what a read sees before
// any assignment.
let f = null;
const ff: number = f;
let g = undefined;
const gg: number = g;
