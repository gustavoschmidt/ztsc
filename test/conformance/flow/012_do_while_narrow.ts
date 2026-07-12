declare function next(): string | null;
let cur: string | null = next();
while (cur !== null) {
  const s: string = cur;
  cur = next();
}
