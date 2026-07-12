import { Animal } from "./animal";
class Dog extends Animal {
  bark(): string { return this.name; }
}
const d = new Dog("rex");
const s: string = d.bark();
const n: number = d.name;
