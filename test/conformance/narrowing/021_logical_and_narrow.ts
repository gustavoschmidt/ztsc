function f(x: { name: string } | null): string {
  if (x && x.name) { return x.name; }
  return "";
}
