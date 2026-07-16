// `this.p` property-path narrowing: truthiness guards, assignment
// narrowing, and invalidation by a later assignment.
interface Ob<T> {
  next: (v: T) => void;
}
class Box<T> {
  observers: Ob<T>[] = [];
  current: Ob<T>[] | null = null;
  name: string | null = null;

  fill() {
    if (!this.current) {
      this.current = Array.from(this.observers);
    }
    for (const o of this.current) {
      o.next;
    }
  }

  guard() {
    if (this.name) {
      this.name.toUpperCase();
      const n: string = this.name;
    }
    this.name.toUpperCase(); // possibly null
  }

  invalidate() {
    if (this.name) {
      this.name = null;
      this.name.toUpperCase(); // narrowed to null by the assignment
    }
  }
}
