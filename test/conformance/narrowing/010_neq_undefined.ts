function f(x: number | undefined): number {
  if (x !== undefined) { return x; }
  return 0;
}
