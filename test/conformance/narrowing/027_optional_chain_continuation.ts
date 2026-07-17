// Every access after a `?.` is part of the chain and short-circuits together,
// so a continuation on a non-nullish tail is clean; but an *inherently*
// nullable intermediate still reports.
interface Inner { c: number; }
declare const clean: { b: Inner } | undefined;
declare const nullableMid: { b: Inner | null } | undefined;
declare const undefMid: { b: Inner | undefined } | undefined;

const a: number | undefined = clean?.b.c;          // clean continuation
const s: string | undefined = clean?.b.c.toString();
const bad1 = nullableMid?.b.c;                      // b possibly null
const bad2 = undefMid?.b.c;                         // b possibly undefined

void a; void s; void bad1; void bad2;
