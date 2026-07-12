function f(x: string | number | boolean): number {
  switch (typeof x) {
    case "string": return x.length;
    case "number": return x;
    case "boolean": return 0;
  }
}
