function greet(name = "anon") { return name; }
const s: string = greet();
const t: string = greet("bob");
greet(1);
