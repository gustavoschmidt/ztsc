// A wrong nested property value elaborates to TS2322 at the value, like an
// assignment, rather than the top-level TS1360.
interface T { a: string; }
const c = { a: 1 } satisfies T;
