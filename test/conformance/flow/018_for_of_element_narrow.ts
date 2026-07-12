declare const items: (number | null)[];
function sum(): number {
  let total = 0;
  for (const it of items) {
    if (it !== null) { total = total + it; }
  }
  return total;
}
