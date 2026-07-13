async function f() {
  const p: Promise<string> = Promise.resolve("a");
  const s: string = await p;
  const n: number = await p;
}
