// An intersection's call/construct signature list is the CONCATENATION of its
// constituents' lists (tsc's `resolveIntersectionTypeMembers`), and
// `getSignaturesOfType` on an interface reads that interface's RESOLVED
// members — so a signature a constituent merely INHERITS is in the list too.
// A conditional's `infer` therefore matches an intersection whose only callable
// member is an interface or type literal, not just one carrying a bare function
// type. Oracle: tsgo 7.0.2 reports exactly the marked lines.
//
// This is the shape every `styled(Component)` value has
// (`string & StyledComponentBase<…> & NoStringRefRes`), so
// `ComponentProps<typeof Styled>` used to fall to `JSXElementConstructor`'s
// fallback and every prop of every styled component was an excess error.

interface Callable<P> {
  (props: P): "called";
  readonly brand: symbol;
}
interface Derived<C> extends Callable<{ a: number }> {
  inner: C;
}
type Idx = { [k: string]: any; [k: number]: any };

// (1) the callable member is an interface with a DIRECT call signature
type Fn<T> = T extends (p: infer P) => any ? P : "false-branch";
type F1 = Fn<Callable<{ a: number }> & { z: 1 }>;
declare const f1: F1;
const f1_bad: "false-branch" = f1; // TS2322
const f1_ok: { a: number } = f1;

// (2) the call signature is INHERITED by the callable member
type F2 = Fn<Derived<any> & Idx>;
declare const f2: F2;
const f2_bad: "false-branch" = f2; // TS2322
const f2_ok: { a: number } = f2;

// (3) `string &` in front — the real styled-components shape
type F3 = Fn<string & Derived<any> & Idx>;
declare const f3: F3;
const f3_bad: "false-branch" = f3; // TS2322
const f3_ok: { a: number } = f3;

// (4) a CONSTRUCT-signature pattern, whose source signature also lives inside
// an object member. `new (…) => R` is an object type with one construct
// signature, so this exercises the `.object` pattern arm, not the function one.
interface Ctor<P> {
  new (p: P): "constructed";
}
type Ct<T> = T extends new (p: infer P) => any ? P : "false-branch";
type F4 = Ct<Ctor<{ b: string }> & { z: 1 }>;
declare const f4: F4;
const f4_bad: "false-branch" = f4; // TS2322
const f4_ok: { b: string } = f4;

// (5) a union pattern with one function and one constructor constituent —
// `JSXElementConstructor<infer P>` exactly. Either arm may supply the answer.
type JC<P> = ((props: P) => any) | (new (p: P) => any);
type CP<T> = T extends JC<infer P> ? P : "false-branch";
type F5 = CP<string & Derived<any> & Idx>;
declare const f5: F5;
const f5_bad: "false-branch" = f5; // TS2322
const f5_ok: { a: number } = f5;

// (6) the END-aligned rule still decides between two callable members, and an
// object-member signature takes part in it on equal terms with a bare one.
type Two = Callable<{ first: 1 }> & ((p: { second: 2 }) => any);
type F6 = Fn<Two>;
declare const f6: F6;
const f6_first: { first: 1 } = f6; // TS2741 — the LAST member wins
const f6_second: { second: 2 } = f6;

type TwoRev = ((p: { second: 2 }) => any) & Callable<{ first: 1 }>;
type F7 = Fn<TwoRev>;
declare const f7: F7;
const f7_second: { second: 2 } = f7; // TS2741
const f7_first: { first: 1 } = f7;

// (7) a non-callable intersection must still take the FALSE branch.
type F8 = Fn<{ a: 1 } & { b: 2 }>;
declare const f8: F8;
const f8_ok: "false-branch" = f8;

export { f1_bad, f1_ok, f2_bad, f2_ok, f3_bad, f3_ok, f4_bad, f4_ok };
export { f5_bad, f5_ok, f6_first, f6_second, f7_second, f7_first, f8_ok };
