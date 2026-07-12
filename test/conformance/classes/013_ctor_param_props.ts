class User {
  constructor(private id: number, readonly name: string) {}
  getId(): number { return this.id; }
}
const u = new User(1, "a");
const s: string = u.name;
