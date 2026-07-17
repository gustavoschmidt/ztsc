// A `const` (or effectively-const) reference keeps its outer narrowing when
// captured by a nested closure; tsc narrows const across closure boundaries.
declare function getStr(): string | null;

function useConstInClosure(): number {
  const c = getStr();
  if (c) {
    const g = () => c.length; // c is const, narrowed to string here
    return g();
  }
  return 0;
}

function guardThenFilter(arr: number[], d: Date | null): number[] {
  const buyDate = d;
  if (arr.length > 0 && buyDate) {
    // buyDate narrowed non-null; still non-null inside the filter closure.
    return arr.filter((x) => x <= buyDate.getTime());
  }
  return [];
}

function earlyThrowThenForEach(v: string | undefined): void {
  const s = v;
  if (!s) throw new Error();
  [1, 2].forEach((n) => {
    const _ = s.length + n; // s narrowed to string inside the closure
    void _;
  });
}

void useConstInClosure;
void guardThenFilter;
void earlyThrowThenForEach;
