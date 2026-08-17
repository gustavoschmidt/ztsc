// The endpoint ("does control fall off the end?") walk asks of every
// statement-position call whether its signature returns `never`, and answering
// that resolves — and MEMOIZES — the callee's type. So the walk has to resolve
// it in the block the call is written in, or the memo pins the wrong symbol for
// the authoritative check that follows.
//
// Every function here needs its return type inferred, which is what puts the
// endpoint walk in front of the call.
declare function fail(msg: string): never;

// A block-scoped `function` shadowing the enclosing one: the calls inside the
// block are the INNER `foo`, both when they fit and when they do not.
function foo(a: number) {
  if (a === 1) {
    function foo() {}
    foo();
    foo(10); // TS2554: the inner foo takes none
  } else {
    function foo() {}
    foo();
    foo(10); // TS2554
  }
  foo(10);
  foo();   // TS2554: the outer foo takes one
}

// A callee declared only inside the block still resolves there.
function block(flag: boolean) {
  if (flag) {
    const render = (): string => "x";
    render();
  } else {
  }
}

// The same, through a `catch` clause and a `switch` case block — both bind
// their bodies in a scope of their own.
function clauses(k: 0 | 1) {
  try {
    fail("boom");
  } catch (e) {
    const report = (): string => "x";
    report();
  }
  switch (k) {
    case 0: {
      const step = (): string => "x";
      step();
      break;
    }
    default:
      break;
  }
}

export { foo, block, clauses };
