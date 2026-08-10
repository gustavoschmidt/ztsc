// tsc's `getUnmatchedProperty`: `propertiesRelatedTo` scans the WHOLE target
// for a required property the source has not got, and fails on that alone,
// before it relates a single member TYPE. ztsc used to interleave the two —
// presence and type were asked per property, in property order — so a pair
// that is dead on a name the walk reaches late paid a full recursive relation
// for every name ahead of it.
//
// The verdict is the same either way; what changes is how much work reaching
// it costs. On a fluent generic API whose every member hands back a wrapper
// around `this`, the difference is unbounded: each member comparison recurses
// into another instantiation of the same family, so the walk that never had to
// happen is the expensive one. This pins the verdicts, which the reordering
// must leave alone.

// -- the missing name is the LAST property by any ordering ------------------

interface Wide {
  aaa: number;
  bbb: string;
  ccc: boolean;
  zzz: number;
}
declare const lacksZzz: {aaa: number; bbb: string; ccc: boolean};
const w1: Wide = lacksZzz; // no `zzz`

// -- a missing name and a type mismatch in the same pair --------------------
//
// The reordering decides this pair on `zzz` where the interleaved walk decided
// it on `aaa`. Both are failures and neither is the other's cause, so the
// verdict must not move.

declare const lacksZzzAndWrongAaa: {aaa: string; bbb: string; ccc: boolean};
const w2: Wide = lacksZzzAndWrongAaa;

// -- an OPTIONAL target property the source lacks is not a mismatch ---------

interface WideOpt {
  aaa: number;
  zzz?: number;
}
declare const noZzz: {aaa: number};
const w3: WideOpt = noZzz;

// -- an optional SOURCE property does not satisfy a required target one -----
//
// Present by NAME, so the name scan passes it through to the type comparison,
// which is where `undefined` fails. A name-only pre-pass must not answer here.

declare const optionalZzz: {
  aaa: number;
  bbb: string;
  ccc: boolean;
  zzz?: number;
};
const w4: Wide = optionalZzz;

// -- the fluent `this`-returning family the rule exists for ------------------
//
// Every member of `Base` hands back a wrapper parameterised by `this`, so
// relating any two members recurses into a strictly larger instantiation of
// the same three generics. `Opt` declares `unwrap`, which `Str` has not got,
// so the pair is decided on that name and none of the members are compared.

declare class Base<Out> {
  readonly _out: Out;
  optional(): Opt<this>;
  boxed(): Box<this>;
  chained(): Chain<this, Out>;
  paired(): Box<Chain<this, Out>>;
}
declare class Opt<T extends Base<unknown>> extends Base<T['_out'] | undefined> {
  unwrap(): T;
}
declare class Box<T extends Base<unknown>> extends Base<T['_out']> {}
declare class Chain<T extends Base<unknown>, Out> extends Base<Out> {
  readonly _src: T;
}
declare class Str extends Base<string> {}

declare function takeOpt(o: Opt<Base<unknown>>): void;
declare const str: Str;
takeOpt(str); // `Str` has no `unwrap`

declare const opt: Opt<Str>;
takeOpt(opt);
