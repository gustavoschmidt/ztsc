function assertNum(x: string | number): number {
  if (typeof x === "string") { throw x; }
  return x;
}
