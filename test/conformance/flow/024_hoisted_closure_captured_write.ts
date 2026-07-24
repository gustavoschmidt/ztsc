// A hoisted `function` (or any closure) declared in unreachable code — after a
// `return` — can still be invoked; its body runs in a fresh reachable context.
// A captured `const` reference read/written inside it must use its DECLARED
// type, not `never`. Crossing into the closure's unreachable definition point
// would collapse the reference to `never`; a property *read* to `never` is
// silently accepted, but a property *write* target would spuriously fail
// ("Type '0' is not assignable to type 'never'"). Both must stay clean.
function useCounter() {
  const ref = { current: 0 };
  return { reset, tick };

  function reset() {
    ref.current = 0; // clean: write target is `number`, not `never`
  }
  function tick() {
    const id = ++ref.current;
    if (id !== ref.current) return;
  }
}
const c = useCounter();
c.reset();
