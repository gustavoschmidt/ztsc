// TS 5.4 "preserved narrowing in closures following the last assignment".
// `checkIdentifier`'s flow-container hoisting loop extends the flow of a
// reference inside a function expression / arrow / object-or-class-expression
// method out to the enclosing container when the referenced symbol is a
// parameter or mutable local AND the reference is `isPastLastAssignment` —
// i.e. textually after every assignment to that symbol, where an assignment's
// position is `extendAssignmentPosition`-extended to the end of the outermost
// enclosing statement that begins after the declaration.
//
// The positive cases below are ones tsc accepts for exactly that reason; the
// negative ones pin the boundaries that keep the rule from over-applying (an
// assignment after the closure, an assignment sharing a statement with the
// closure, an assignment made from a nested function, an exported binding, a
// `var`, and a crossing container that is a function *declaration*).
declare function use(s: string): void;
declare function reg(f: () => void): void;
declare const cond: boolean;

// --- accepted: the reference is past the one assignment --------------------
export function assignedOnceBefore() {
  let x: string | undefined;
  x = 'hi';
  if (x) {
    reg(() => {
      use(x);
    });
  }
}

// The assignment's position is the END of the statement that encloses it, so
// a closure in a LATER sibling statement is past it.
export function assignedInsideAnEarlierStatement() {
  let x: string | undefined;
  if (cond) {
    x = 'hi';
  }
  while (cond) {
    x = 'ho';
  }
  if (x) {
    reg(() => {
      use(x);
    });
  }
}

// A bare block is not one of the statement kinds tsc extends to, so the
// extension stops at the expression statement inside it.
export function assignedInsideABareBlock() {
  let x: string | undefined;
  {
    x = 'hi';
  }
  if (x) {
    reg(() => {
      use(x);
    });
  }
}

// A never-assigned parameter needs no position at all.
export function neverAssignedParameter(p?: string) {
  if (p) {
    reg(() => {
      use(p);
    });
  }
}

// A reassigned parameter is a mutable local like any other.
export function reassignedParameter(p?: string) {
  p = 'hi';
  if (p) {
    reg(() => {
      use(p);
    });
  }
}

// A `catch` variable is one too.
export function catchVariable() {
  try {
    // empty
  } catch (e) {
    if (typeof e === 'string') {
      reg(() => {
        use(e);
      });
    }
  }
}

// The hoisting loop runs until the containers match, so nesting is fine.
export function twoClosuresDeep() {
  let x: string | undefined;
  x = 'hi';
  if (x) {
    reg(() => {
      reg(() => {
        use(x);
      });
    });
  }
}

// A class-expression method is one of the containers that extends the flow.
export function classExpressionMethod() {
  let x: string | undefined;
  x = 'hi';
  if (x) {
    const C = class {
      m() {
        use(x);
      }
    };
    void C;
  }
}

// A MODULE's top-level `let` is a module-local, not a global, so it is a
// mutable local variable like any other. (A SCRIPT's top-level `let` is not —
// flow/065 is that file, and its narrowing does not cross.)
let moduleLocal: string | undefined;
moduleLocal = 'hi';
export function readsAModuleLocal() {
  if (moduleLocal) {
    reg(() => {
      use(moduleLocal);
    });
  }
}

// --- rejected: each boundary of the rule -----------------------------------

// Assigned again after the closure: the reference is not past that assignment.
export function assignedAfterTheClosure() {
  let x: string | undefined;
  x = 'hi';
  if (x) {
    reg(() => {
      use(x);
    });
  }
  x = undefined;
}

// A compound assignment after the closure counts as an assignment.
export function compoundAssignedAfterTheClosure() {
  let x: string | undefined;
  x = 'hi';
  if (x) {
    reg(() => {
      use(x);
    });
  }
  x += '!';
}

// The assignment and the closure share an enclosing `if` statement, so the
// extension puts the assignment's position past the reference.
export function assignedInTheSameStatement() {
  let x: string | undefined;
  if (cond) {
    x = 'hi';
    if (x) {
      reg(() => {
        use(x);
      });
    }
  }
}

// Same, one loop iteration later.
export function assignedInTheSameLoop() {
  let x: string | undefined;
  while (cond) {
    x = 'hi';
    if (x) {
      reg(() => {
        use(x);
      });
    }
  }
}

// An assignment made from a NESTED function can run at any time.
export function assignedFromANestedFunction() {
  let x: string | undefined;
  x = 'hi';
  reg(() => {
    x = undefined;
  });
  if (x) {
    reg(() => {
      use(x);
    });
  }
}

// An exported binding is not a mutable *local*.
export let exported: string | undefined;
exported = 'hi';
export function readsTheExportedBinding() {
  if (exported) {
    reg(() => {
      use(exported);
    });
  }
}

// `var` is hoisted out of the block it is written in, so it is not a mutable
// local either.
export function assignedVar() {
  var x: string | undefined;
  x = 'hi';
  if (x) {
    reg(() => {
      use(x);
    });
  }
}

// Only function expressions / arrows / object-and-class-expression methods
// extend the flow; a hoisted function DECLARATION captures at its definition
// point, before any guard.
export function crossingAFunctionDeclaration() {
  let x: string | undefined;
  x = 'hi';
  if (x) {
    function inner() {
      use(x);
    }
    inner();
  }
}
