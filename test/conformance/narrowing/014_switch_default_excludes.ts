function f(x: "a" | "b"): number {
  switch (x) {
    case "a": return 0;
    case "b": return 1;
    default: {
      const n: never = x;
      return n;
    }
  }
}
