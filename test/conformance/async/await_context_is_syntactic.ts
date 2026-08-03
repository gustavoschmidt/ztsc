// `await` legality is a property of where the expression is WRITTEN, not of
// whichever function frame happens to be in flight when the checker reaches
// it. tsc records it in the parser (`NodeFlags.AwaitContext`).
//
// An expression is re-checked whenever a later contextual type demands a
// different reading of it, and the re-entry can come from anywhere. Resolving
// `counts` inside the callback of `[…].map(t => … counts …)` re-enters the
// initializer of `const counts = await db` — a different contextual type, so
// a different memo key — while the frame in flight is the ARROW's. The arrow
// is not async, so a perfectly correct `await` in the enclosing async method
// was reported as TS1308 (immich's `getIntegrityReportSummary`).

declare const db: Promise<number[]>;

class R {
  // Legal, and the shape that re-enters the initializer.
  async ok() {
    const counts = await db;
    return [1].map((t) => t + counts.length);
  }

  // Legal: an async arrow inside a NON-async method.
  outerNotAsync() {
    const f = async () => {
      const y = await db;
      return y.length;
    };
    return f();
  }

  // An error, and it must stay one: a non-async method.
  notAsync() {
    const x = await db;
    return x;
  }

  // An error too: a non-async arrow inside an async method.
  async innerNotAsync() {
    const f = () => {
      const y = await db;
      return y;
    };
    return f();
  }
}

export { R };
