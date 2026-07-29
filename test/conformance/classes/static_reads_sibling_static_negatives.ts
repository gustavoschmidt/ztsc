// Negatives for the sibling-static resolution: the member's real type must be
// enforced at the use site, not silently accepted as `any`.

class SrnCache {
  private static store: { hit: number } = { hit: 1 };

  public static read = <T extends { k: string }>(key: T) => {
    return SrnCache.store.hit;
  };

  public static twice = <T extends { k: string }>(key: T) => {
    const one = SrnCache.read(key);
    return one + one;
  };
}

declare const srnKey: { k: string };
const srnBad1: string = SrnCache.twice(srnKey);
SrnCache.twice(srnKey).k;
SrnCache.read(srnKey).k;

class SrnChain {
  static first = () => SrnChain.second() + 1;
  static second = () => SrnChain.third() + 1;
  static third = () => 1;
}
const srnBad2: string = SrnChain.first();

class SrnBase {
  static tag = "base";
}
class SrnDerived extends SrnBase {
  static loud = () => SrnDerived.tag;
}
const srnBad3: number = SrnDerived.loud();

// A missing static is still a missing static.
SrnCache.absent;
