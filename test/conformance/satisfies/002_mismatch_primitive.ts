// A primitive that is not assignable to the target is TS1360.
const s = "hello" satisfies number;
type Dir = "n" | "s" | "e" | "w";
const d = "x" satisfies Dir;
