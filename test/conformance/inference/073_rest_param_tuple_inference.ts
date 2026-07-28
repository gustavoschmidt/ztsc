// A trailing REST parameter in the pattern signature must infer the TUPLE of the
// argument signature's residual parameters, not pair 1:1 with the parameter that
// happens to sit in that slot.
declare const wrap: <T extends any[]>(fn: (...args: T) => void) => (...args: T) => void;

const g = wrap((q: string, n: number, cb: (items: number[]) => void) => {
  void q;
  void n;
  void cb;
});
// contextually typed from the inferred tuple — no implicit any, no arity error
g("x", 1, (items) => {
  void items.length;
});
// arity is now enforced against the tuple
g("x", 1); // TS2554
// and so are the element types
g(1, 1, (items) => {
  void items;
}); // TS2345

// leading fixed params in the pattern still pair positionally, the rest gathers
declare const wrap2: <T extends any[]>(
  head: string,
  fn: (first: boolean, ...rest: T) => void,
) => (...rest: T) => void;
const h = wrap2("k", (first: boolean, a: string, b: number) => {
  void first;
  void a;
  void b;
});
h("s", 2);
h(2, 2); // TS2345 on the first tuple element

// an OPTIONAL residual source param becomes an optional tuple element
declare const wrap3: <T extends any[]>(fn: (...args: T) => void) => (...args: T) => void;
const i3 = wrap3((a: string, b?: number) => {
  void a;
  void b;
});
i3("x");
i3("x", 1);
i3("x", "y"); // TS2345

// the source's OWN trailing rest passes through unwrapped (no one-element tuple)
const j = wrap3((...nums: number[]) => {
  void nums;
});
j(1, 2, 3);
j("a"); // TS2345

// a pattern with NO rest parameter is unaffected
declare const plain: <A, B>(fn: (a: A, b: B) => void) => (a: A, b: B) => void;
const k = plain((a: string, b: number) => {
  void a;
  void b;
});
k("s", 1);
k(1, 1); // TS2345 on the first parameter
