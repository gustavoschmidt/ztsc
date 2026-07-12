class Cat { meow(): string { return "m"; } }
class Dog { bark(): string { return "w"; } }
function speak(a: Cat | Dog): string {
  if (a instanceof Cat) { return a.meow(); }
  return a.bark();
}
