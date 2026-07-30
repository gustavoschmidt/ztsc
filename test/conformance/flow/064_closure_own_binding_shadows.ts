// A closure's OWN bindings are not captured references, so flow analysis must
// stop at the closure's start rather than continue into the definition-point
// flow of the enclosing function. Continuing let a same-named enclosing local
// narrow the closure's parameter: `assignNarrows` matches a declarator by name,
// so `const d: string = "outer"` reduced an `unknown`-typed parameter `d` to
// `string`. Only a declared type that assignment-narrowing refines shows it,
// which is why `unknown` is the shape under test.
declare function takeUnknown<T>(cb: (v: unknown) => T): T;
declare function takeTuple<T>(cb: (v: [number, unknown]) => T): T;
declare function takeObject<T>(cb: (v: { d: unknown }) => T): T;

// 1. Contextually typed arrow parameter shadowing an enclosing `const`.
function f1() {
  const d: string = 'outer';
  return takeUnknown((d) => ({ e: d }));
}
const c1: { e: number } = f1(); // TS2322: e is unknown, not string

// 2. Same, with an explicit annotation on the parameter.
function f2() {
  const d: string = 'outer';
  return takeUnknown((d: unknown) => ({ e: d }));
}
const c2: { e: number } = f2(); // TS2322

// 3. Destructured tuple parameter.
function f3() {
  const d: string = 'outer';
  return takeTuple(([n, d]) => ({ e: d }));
}
const c3: { e: number } = f3(); // TS2322

// 4. Destructured object parameter.
function f4() {
  const d: string = 'outer';
  return takeObject(({ d }) => ({ e: d }));
}
const c4: { e: number } = f4(); // TS2322

// 5. Function expression, and an enclosing `let` (whose flow type at the
//    closure's definition point is `number`).
function f5() {
  let d = 42;
  return takeTuple(function ([n, d]) {
    return { e: d };
  });
}
const c5: { e: number } = f5(); // TS2322

// 6. A `const` declared inside the closure body, shadowing the outer one.
function f6() {
  const d: string = 'outer';
  return takeUnknown((v) => {
    const d: unknown = v;
    return { e: d };
  });
}
const c6: { e: number } = f6(); // TS2322

export { c1, c2, c3, c4, c5, c6 };
