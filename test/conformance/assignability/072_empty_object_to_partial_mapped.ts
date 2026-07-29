// tsc's `structuredTypeRelatedTo`: "An empty object type is related to any
// mapped type that includes a '?' modifier." Every key such a map produces is
// optional, so a source with no members satisfies all of them — even while the
// map's key set is still generic.
class Delta<T> {
  private constructor(
    public deleted: Partial<T>,
    public inserted: Partial<T>,
  ) {}
  public static create<T>(deleted: Partial<T>, inserted: Partial<T>) {
    return new Delta(deleted, inserted);
  }
  public static empty() {
    return Delta.create({}, {});
  }
  // `Delta.empty()` is a `Delta<unknown>`, whose `deleted`/`inserted` are
  // `Partial<unknown>` = `{}`; each has to reach the still-deferred
  // `Partial<T>`.
  public static calculate<T extends { [key: string]: any }>(
    prev: T,
    next: T,
  ): Delta<T> {
    if (prev === next) {
      return Delta.empty();
    }
    return Delta.create({} as Partial<T>, {} as Partial<T>);
  }
}

// The rule directly.
declare function takesPartial<T>(p: Partial<T>): void;
export function direct<T>() {
  takesPartial<T>({});
}

// Negative: the map does NOT add `?`, so an empty source is still rejected.
type Req<T> = { [P in keyof T]-?: T[P] };
declare function takesReq<T>(p: Req<T>): void;
export function negRequired<T extends { a: number }>() {
  takesReq<T>({});
}

// Negative: a NON-empty source does not get the free pass — it still has to
// relate property-wise, and `a` is a key `Partial<T>` may not have. (Not a
// fresh literal, so this is the relation talking, not the excess-property
// check.)
export function negNonEmpty<T>(v: { a: number }) {
  takesPartial<T>(v);
}

export default Delta;
