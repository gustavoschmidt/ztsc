import "./aug";

// Value side: `console` keeps its `Console` methods through the namespace
// merge (each would be a phantom TS2339 if the namespace object shadowed the
// declared `var console: Console`).
console.log("hello");
console.error("oops");
console.warn("warn");

// Type side: the merged namespace still contributes its exported types.
const opts: console.Options = { color: true };
void opts;

// The only real error: `console.log` returns `void`, not `number`.
const bad: number = console.log("z");
void bad;
