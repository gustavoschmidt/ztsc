declare const xs: (string | null)[];
function f(): string {
  for (const x of xs) {
    if (x === null) { continue; }
    return x;
  }
  return "";
}
