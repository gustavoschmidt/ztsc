// A sibling narrowing survives a closure. tsc asks `getFlowTypeOfReference`
// about the binding PATTERN with no `flowContainer`, so the walk crosses every
// function-start boundary — it may, because the pattern only ever stands for a
// `const` declarator or a never-assigned parameter.
type Q =
  | { isPending: true; data: undefined }
  | { isPending: false; data: { n: number }[] };
declare function q(): Q;

declare function each<T, R>(xs: T[], f: (x: T, i: number) => R): R[];

function insideCallback(): number[] | null {
  const { data, isPending } = q();
  if (isPending) {
    return null;
  }
  return each(data, (x, i) => x.n + i + data.length);
}

// Two closures deep.
function nested(): number | null {
  const { data, isPending } = q();
  if (isPending) {
    return null;
  }
  const outer = () => {
    const innerFn = () => data.length;
    return innerFn();
  };
  return outer();
}

// A parameter destructuring, read from a closure.
function paramPattern({ data, isPending }: Q): () => number {
  if (isPending) {
    return () => 0;
  }
  return () => data.length;
}

export { insideCallback, nested, paramPattern };
