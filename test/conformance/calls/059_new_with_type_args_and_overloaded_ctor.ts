// `new C<A>(…)`'s type arguments belong to the CLASS. ztsc spent them on the
// class — arity checked, instance type built, every constructor signature
// instantiated with them — and then handed the SAME list on as the
// constructor SIGNATURE's own explicit type arguments, where it was measured
// against the constructor's own type parameters (normally none) and every
// candidate was rejected on arity.
//
// tsc has no such double-spend: the construct signatures of `typeof C` carry
// the class's parameters as their own. Visible only with an OVERLOADED
// constructor, because a lone candidate is not dropped for it — which is why
// `new Kysely<DB>(config)` in immich was TS2769 while `new Kysely(config)`
// was clean.

interface Cfg {
  readonly dialect: string;
  readonly log?: number;
}
interface Props {
  readonly config: Cfg;
  readonly driver: string;
}

declare class Base<DB> {
  q(): DB;
}

declare class Db<DB> extends Base<DB> {
  constructor(a: Cfg);
  constructor(a: Props);
}

declare const cfg: Cfg;
declare const props: Props;

export const withArgs = new Db<{ x: 1 }>(cfg);
export const withArgsProps = new Db<{ x: 1 }>(props);
export const inferred = new Db(cfg);

// The instance type still comes from the written argument.
export const kept: Base<{ x: 1 }> = withArgs;

// A constructor with its OWN type parameters still takes explicit arguments
// for the class alone.
declare class Holder<T> {
  constructor(a: Cfg);
  constructor(a: Props);
  take(v: T): void;
}
export function holder() {
  new Holder<string>(cfg).take("s");
}

// Negative control: no overload matches a wrong argument.
export const wrong = new Db<{ x: 1 }>(42);

// Negative control: the instance type is still checked.
export const wrongInstance: Base<{ y: 2 }> = new Db<{ x: 1 }>(cfg);

// Negative control: a single-signature constructor is unaffected.
declare class One<T> {
  constructor(a: Cfg);
  take(v: T): void;
}
export function one() {
  new One<string>(cfg).take(42);
}
