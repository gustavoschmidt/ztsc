// tsc's `reorderCandidates`: overload RESOLUTION groups a candidate list by
// `signature.declaration.parent` and splices each new group in at the FRONT,
// so the declaration groups are visited back-to-front with the order inside a
// group preserved. An `interface` reopened twice is ONE symbol but TWO
// parents, so its two call signatures resolve in reverse declaration order —
// and the LAST candidate, which is the one a failed resolution reports
// against, is the FIRST declaration's.
//
// The reversal is call-site-only: `getSignaturesOfType` keeps declaration
// order, and `ReturnType`/`Parameters`/`inferFromSignatures` all align from
// the END of that order, so they still answer with the LAST declaration.
//
// This is tippy.js's shape (`SingleTarget = Element`,
// `MultipleTargets = string | Element[] | NodeList`), and WHICH candidate is
// last is observable in the reported position: a `string` first argument
// matches only the SECOND declaration's parameter, so that candidate fails on
// argument 1 and the FIRST declaration's fails on argument 0. Report the last
// candidate and the error lands on argument 0.
interface Target {
  readonly nodeName: string;
}
interface Props {
  content: string;
}
interface Inst<T> {
  props: T;
}

interface Tip<T = Props> extends Target {
  (targets: Target, optionalProps?: Partial<T>): Inst<T>;
}
interface Tip<T = Props> extends Target {
  (targets: string | Target[], optionalProps?: Partial<T>): Inst<T>[];
}
declare const tip: Tip;

// Each declaration's own signature still resolves.
const one: Inst<Props> = tip(null as unknown as Target);
const many: Inst<Props>[] = tip(['a'] as unknown as Target[]);
void one;
void many;

// Matching NEITHER is TS2769. The last candidate is the FIRST declaration's,
// whose parameter 0 rejects the string, so the error is reported at argument
// 0 — on this line — and NOT inside the options literal a line below, which
// is where the SECOND declaration's failure elaborates (it accepts the string
// and only rejects `content`). The two orders therefore differ by LINE, which
// is what makes this snapshot a real gate: without `reorderCandidates` the
// diagnostic moves to line 48. In social-app it moved out from under an
// `@ts-ignore` that only reaches the call line.
const bad = tip('body', {
  content: 123,
});
void bad;

// Declaration order is what everything other than resolution reads: the LAST
// declaration's signature is the one `ReturnType`/`Parameters` align to.
type R = ReturnType<typeof tip>;
const r: Inst<Props>[] = null as unknown as R;
void r;
type P0 = Parameters<typeof tip>[0];
const p: string | Target[] = null as unknown as P0;
void p;

// A single-declaration interface has one group and is unaffected.
interface Solo {
  (a: string): number;
  (a: number): string;
}
declare const solo: Solo;
const s: number = solo('a');
const t: string = solo(1);
void s;
void t;
const soloBad = solo(true);
void soloBad;

// An inherited call signature belongs to a different declaring symbol, so it
// stays after the reversed groups rather than joining them.
interface BaseCallable {
  (flag: boolean): 'base';
}
interface Derived extends BaseCallable {
  (a: string): 'first';
}
interface Derived extends BaseCallable {
  (a: number): 'second';
}
declare const d: Derived;
const d1: 'first' = d('a');
const d2: 'second' = d(1);
const d3: 'base' = d(true);
void d1;
void d2;
void d3;
export {};
