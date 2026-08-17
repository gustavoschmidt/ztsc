// tsc's `FlowFlags.ReduceLabel`. The `finally` block is entered from every
// way control can reach it — including an exception raised part-way through
// the `try` block — so a read INSIDE it sees the pre-try state and `a` is
// still possibly unassigned there. Leaving the statement NORMALLY means no
// exception was raised, so that edge is dropped on the way out and `a` is
// definitely assigned afterwards.
declare function op(): number;
declare function close(): void;

function normalExit(): number {
  let a: number;
  try {
    a = op();
  } finally {
    close();
  }
  return a; // assigned: the exception edge cannot reach here
}

function insideFinally(): number {
  let b: number;
  try {
    b = op();
  } finally {
    return b; // NOT assigned: the try block may have thrown before the write
  }
}

// A catch block that completes normally is a second normal-exit edge, and it
// does not assign — so the join after the statement is not definite.
function withCatch(): number {
  let c: number;
  try {
    c = op();
  } catch {
  } finally {
    close();
  }
  return c;
}

// The finally block's own assignment survives the reduction.
function assignedInFinally(): number {
  let d: number;
  try {
    op();
  } finally {
    d = 1;
  }
  return d;
}

export { normalExit, insideFinally, withCatch, assignedInFinally };
