async function fetchNum(): Promise<number> { return 1; }
async function use() {
  const n: number = await fetchNum();
  const bad: string = await fetchNum();
}
