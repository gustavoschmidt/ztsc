// A function-local `let` or parameter that is never reassigned is effectively
// `const`: tsc keeps its narrowing when the reference is captured by a nested
// function-expression / arrow (but not through a hoisted function declaration,
// and not for module-level or reassigned variables — see flow/016).
declare function get(): string | null;

function localLetInClosure(): number {
  let s = get();          // never reassigned -> effectively const
  if (s === null) throw new Error();
  const g = () => s.length; // s narrowed to string inside the arrow
  return g();
}

function paramInClosure(p: string | null): number {
  if (!p) return 0;
  const g = () => p.length; // p narrowed to string inside the arrow
  return g();
}

function guardThenFilter(arr: number[], d: Date | null): number[] {
  let buyDate = d;
  if (arr.length > 0 && buyDate) {
    return arr.filter((x) => x <= buyDate.getTime());
  }
  return [];
}

void localLetInClosure; void paramInClosure; void guardThenFilter;
