async function f(cond: boolean): Promise<number | string> {
  if (cond) return 1;
  return "x";
}
async function bad(cond: boolean): Promise<number> {
  if (cond) return 1;
  return "x";
}
