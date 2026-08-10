// A TYPE QUERY may name the `this` value: `typeof this`, and `typeof
// this.a.b` for anything reached through it. It is the only entity-name
// position where `this` is legal — everywhere else `this` is not a name,
// so the query must not go through name resolution (which reports TS2304
// "Cannot find name 'this'" and leaves the annotation an error type).
//
// `typeof this` reads exactly like `this` in a type position: the
// POLYMORPHIC this type, so a `typeof this` member declared on a base
// class is the SUBCLASS when read through a subclass instance.
//
// `typeof this.x` is different in one respect: it is being resolved as a
// member of the very class that declares `x`, so it asks for a property of
// the home instance while that instance's member table is still being
// folded. tsc answers it because a member's type is resolved per-SYMBOL;
// the whole-table fold can only cut, so the member's own declaration has to
// be read instead. @atproto's `Agent` declares its entire call surface this
// way (`resolveHandle: typeof this.com.atproto.identity.resolveHandle`), and
// a query that fails there erases every response type built on it.

declare class Api {
  com: {
    identity: {
      resolveHandle(params: {handle: string}): Promise<{data: {did: string}}>;
    };
  };
  // self-referential: `com` is a member of this same class
  resolveHandle: typeof this.com.identity.resolveHandle;
  // one level of the same chain
  identity: typeof this.com.identity;
  // the bare query
  self: typeof this;
}

declare class Sub extends Api {
  extra: number;
}

declare const api: Sub;

export async function reads() {
  const r = await api.resolveHandle({handle: 'a'});
  const did: string = r.data.did;
  const r2 = await api.identity.resolveHandle({handle: 'b'});
  const did2: string = r2.data.did;
  return did + did2;
}

// The bare query is the polymorphic `this`, so it is the SUBCLASS here.
export const self: Sub = api.self;

// The query is a real type, not `any`: a wrong assignment must report.
export const wrongCall: number = api.resolveHandle;
export const wrongSelf: number = api.self;

// A generic home class: the query reads with the class's own parameters,
// and the reference's arguments reach it.
declare class Box<T> {
  inner: {value: T};
  value: typeof this.inner.value;
}
declare const box: Box<string>;
export const boxed: string = box.value;
export const boxedWrong: number = box.value;

// The query's type survives generic inference through a callback — the
// social-app shape that first surfaced this (`withResolveTimeout(signal =>
// agent.resolveHandle(…))`).
declare function withRetry<T>(run: () => Promise<T>): Promise<T>;
export async function inferred() {
  const r = await withRetry(() => api.resolveHandle({handle: 'c'}));
  const did: string = r.data.did;
  return did;
}

// `typeof this` is still a value query in a STATIC member: there it names
// the constructor side.
declare class WithStatic {
  static make(): number;
  static alias: typeof this.make;
}
export const staticAlias: number = WithStatic.alias();
