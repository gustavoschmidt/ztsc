function f(x: number | null | undefined): number {
  if (x == null) { return 0; }
  return x;
}
