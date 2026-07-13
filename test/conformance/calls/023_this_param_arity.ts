// A leading `this` parameter is a receiver annotation, not a real parameter:
// it is excluded from arity, so calling with only the real arguments is fine
// (no false TS2554) and `this` is typed as the annotation inside the body.
interface Named {
  name: string;
}
function greet(this: Named, greeting: string): string {
  return greeting + this.name;
}
const obj = { name: "world", greet };
// One real argument — arity is 1, not 2. Receiver `obj` has `name`.
const g: string = obj.greet("hello ");
