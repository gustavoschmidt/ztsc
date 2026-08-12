// A class VALUE (`typeof C`) satisfies a construct-signature target through
// its own constructors, not by fiat: when the class's INSTANCE side is not
// assignable to the signature's return type, `typeof C` is not assignable to
// the signature either. outline's `getActivePolicies(Collection)` against
// `new (...args: never[]) => Model` is this shape (83 keys).
declare class Base {
  f: (x: string) => void;
  id: string;
}
declare class Sub extends Base {
  f: (x: number) => void;
  name: string;
}
declare const s: Sub;
const inst: Base = s;
declare let c1: new (...args: never[]) => Base;
c1 = Sub;
declare let c2: { new (...args: never[]): Base };
c2 = Sub;
declare function takeCtor(c: new () => Base): void;
takeCtor(Sub);
// A class whose instance side IS assignable stays assignable on the static
// side too.
declare class Ok extends Base {
  extra: string;
}
declare let c3: new (...args: never[]) => Base;
c3 = Ok;
export { inst, c1, c2, c3 };
