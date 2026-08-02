// `implements` is not checked when the class inherits from a base ztsc cannot
// resolve — here an `import S = base.Stream;` entity alias, which ztsc keeps
// deliberately lenient (`any`). The instance type is then missing whatever the
// base contributed, so an "incorrectly implements" verdict would describe
// ztsc's gap, not the code. `@types/node`'s `stream.d.ts` (`class ReadableBase
// extends Stream implements NodeJS.ReadableStream`, `Stream` being exactly such
// an alias) reported four of them.
declare module "st" {
  class base {
    pipe(): void;
  }
  namespace base {
    class Stream extends base {}
  }
  import S = base.Stream;
  interface Sink {
    pipe(): void;
    flush(): void;
  }
  class R extends S implements Sink {
    flush(): void;
  }
  export { R };
}

// A class with a fully resolved base still reports TS2420.
interface Named {
  name: string;
  tag(): string;
}
class Base {
  name = "b";
}
class Derived extends Base implements Named {}
class Standalone implements Named {
  name = "s";
}
