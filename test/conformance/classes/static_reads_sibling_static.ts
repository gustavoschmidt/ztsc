// A static member whose initializer reads another static of the same class
// must still get its real type. Resolving the whole static side to answer the
// access typed every sibling, so a sibling reached while this member was still
// in progress saw the in-progress guard's `any` and memoized it.

class SrsCache {
  private static store: { hit: number } = { hit: 1 };

  public static read = <T extends { k: string }>(key: T) => {
    return SrsCache.store.hit;
  };

  public static twice = <T extends { k: string }>(key: T) => {
    const one = SrsCache.read(key);
    return one + one;
  };
}

declare const srsKey: { k: string };
const srsN: number = SrsCache.twice(srsKey);

// The same shape one link longer, with each member reading the next one, which
// is declared after it.
class SrsChain {
  static first = () => SrsChain.second() + 1;
  static second = () => SrsChain.third() + 1;
  static third = () => 1;
}
const srsM: number = SrsChain.first();

// An inherited static still resolves, through the whole static side.
class SrsBase {
  static tag = "base";
}
class SrsDerived extends SrsBase {
  static loud = () => SrsDerived.tag;
}
const srsS: string = SrsDerived.loud();
