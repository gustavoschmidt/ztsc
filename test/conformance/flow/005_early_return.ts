function f(x: number | null): number {
  if (x === null) { return 0; }
  const y: number = x;
  return y;
}
