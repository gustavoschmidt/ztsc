import { Box } from "./lib";

// Constraint satisfied: infers T = { id: number; name: string }.
const good = new Box({ id: 1, name: "ok" });
const okId: number = good.get().id;

// Constraint violated by a non-object argument: inference falls back to the
// constraint `Base` and the argument fails to match -> TS2345. Evaluating the
// constraint requires resolving an AST node that lives in `lib.ts`, which is
// the path that used to panic with an out-of-bounds node index.
const bad = new Box(42);
