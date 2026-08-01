// Negative controls for TS2417 (`classes/033_static_inherit.ts` is the positive
// one). Every derived class here relates to its base's static side, so the
// oracle reports nothing at all — the snapshot is empty on purpose. The check
// runs on EVERY `class … extends …`, so its cost of admission is that none of
// these shapes may trip it: method-parameter bivariance, covariant returns,
// accessors shadowing fields, generic bases, mixin/aliased bases (no base class
// symbol), namespace-merged and ambient classes.

// No shadowing, and an exactly-identical shadow.
class A1 {
  static make(): number {
    return 1;
  }
}
class B1 extends A1 {
  static other(): string {
    return "";
  }
}
class B1b extends A1 {
  static make(): number {
    return 2;
  }
}

// Covariant return, and method-parameter bivariance both ways.
class A2 {
  static create(): A2 {
    return new A2();
  }
  static f(x: string | number): void {}
}
class B2 extends A2 {
  static create(): B2 {
    return new B2();
  }
  static f(x: string): void {} // bivariant: narrower param is fine for methods
}
class B2b extends A2 {
  static f(x: string | number | boolean): void {} // wider param: contravariant
}

// Generic base and generic statics; statics never close over the class's
// type parameters, so the two static sides relate without instantiation.
class A3<T> {
  static tag = "a";
  value!: T;
  static of<U>(u: U): U {
    return u;
  }
}
class B3<T> extends A3<T> {
  static tag = "b";
}
class B3b extends A3<string> {}

// Accessor over field and accessor over accessor.
class A4 {
  static v: number = 1;
}
class B4 extends A4 {
  static get v(): number {
    return 2;
  }
}

// Statics that read sibling statics, plus protected/private statics.
class A5 {
  static a = 1;
  static b = A5.a + 1;
  protected static p = 1;
  private static q = 2;
}
class B5 extends A5 {
  static c = 3;
  static b = 9;
}

// Overloaded statics on both sides.
class A6 {
  static f(x: string): string;
  static f(x: number): number;
  static f(x: any): any {
    return x;
  }
}
class B6 extends A6 {
  static f(x: string): string;
  static f(x: number): number;
  static f(x: any): any {
    return x;
  }
}

// Bases with no class symbol: a mixin application and an aliased class.
const Mixin = <T extends new (...a: any[]) => object>(Base: T) =>
  class extends Base {
    static mixed = true;
  };
class A7 {
  static mixed = false;
}
class B7 extends Mixin(A7) {}
const Alias = A7;
class B7b extends Alias {}

// Namespace-merged base, and an ambient pair.
class A8 {
  static z = 1;
}
namespace A8 {
  export const extra = 2;
}
class B8 extends A8 {}

declare class A9 {
  static d(): void;
}
declare class B9 extends A9 {
  static d(): void;
  static e(): void;
}

// Abstract base, and a three-level chain that stays compatible.
abstract class A10 {
  static k(): number {
    return 0;
  }
  abstract m(): void;
}
class M10 extends A10 {
  m(): void {}
}
class B10 extends M10 {
  static k(): number {
    return 1;
  }
}
