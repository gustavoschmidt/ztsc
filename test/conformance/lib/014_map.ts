const m: Map<string, number> = new Map<string, number>();
const m2: Map<string, number> = m.set("a", 1);
const got: number | undefined = m.get("a");
const has: boolean = m.has("a");
const removed: boolean = m.delete("a");
const size: number = m.size;
m.forEach((value, key) => {
  const v: number = value;
  const k: string = key;
});
m.clear();
