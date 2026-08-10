// `T extends any ? X : Y` is decidably TRUE and must resolve NOW, not defer.
// tsc's `getConditionalType` short-circuits on an `any`/`unknown` extends
// type without ever asking the relation; its only precondition is that the
// CHECK type is not deferred, and tsc's deferral test is shallow
// (`isGenericObjectType || isGenericIndexType`) — a concrete container that
// merely carries free type params inside it is not deferred there.
//
// The forcing idiom is react-query's `NoInfer`, which wraps the type in a
// one-element tuple and indexes it back out with exactly this conditional:
// deferring it leaves an unreduced `[X][X extends any ? 0 : never]` on which
// every property read raises a false TS2339.
type NoInfer<T> = [T][T extends any ? 0 : never];

interface InfiniteData<T, P = unknown> {
  pages: T[];
  pageParams: P[];
}

// A reference carrying a free param — concrete shape, so NOT deferred.
declare function readBack<T>(d: NoInfer<InfiniteData<T>>): void;

function useIt<T>(data: InfiniteData<T>) {
  readBack<T>(data);
}

// The reduction has to survive a property read through the alias.
function reads<T>(d: NoInfer<InfiniteData<T>>) {
  const a: T[] = d.pages;
  const b: unknown[] = d.pageParams;
  return [a, b];
}

// Other concrete-container check types tsc also resolves rather than defers.
type Box<T> = { q: T };
type ViaObject<T> = NoInfer<{ q: T }>;
type ViaRef<T> = NoInfer<Box<T>>;
type ViaArray<T> = NoInfer<T[]>;
type ViaUnion<T> = NoInfer<Box<T> | string>;

function concreteContainers<T>(o: ViaObject<T>, r: ViaRef<T>, a: ViaArray<T>, u: ViaUnion<T>) {
  const x: T = o.q;
  const y: T = r.q;
  const z: T[] = a;
  return [x, y, z, u];
}

// `extends unknown` takes the same short-circuit.
type ViaUnknown<T> = [T][T extends unknown ? 0 : never];
function unknownArm<T>(d: ViaUnknown<Box<T>>) {
  const q: T = d.q;
  return q;
}

// A BARE type variable as the check type stays deferred — it is generic under
// tsc's shallow test, so this must not be resolved by the new arm. The
// distributive conditional still reduces per constituent at instantiation.
type Bare<T> = T extends any ? 0 : never;
declare const bare: Bare<string>;
const bareIsZero: 0 = bare;

export {useIt, reads, concreteContainers, unknownArm, bareIsZero};
