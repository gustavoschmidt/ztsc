// The second half of tsc's `hasExcessProperties`, and it is the whole rule for
// a UNION target. Having found a written property's NAME known somewhere in the
// union, tsc compares the property's VALUE against
// `getTypeOfPropertyInTypes(checkTypes, name)` — the union of that property's
// type over EVERY constituent, with `undefined` standing in for a constituent
// that does not have it — and fails the relation when the value does not fit.
// Nothing else about the union is per-constituent: `unionOrIntersectionRelatedTo`
// then relates the REGULARIZED (no longer fresh) literal to some constituent,
// which never excess-checks again.
//
// Asking instead for ONE constituent that both knows every written property and
// takes the literal whole is stricter than tsc exactly when the properties are
// spread across arms — `@nestjs/swagger`'s `ApiQuery({ name, type })`.
interface Alg {
  name: string;
}

// `iv` is `number` in the one arm that has it and `undefined` in the rest, so a
// wrong `iv` fails even though the bare `Alg` arm would take the regularized
// literal. (The `crypto.subtle.decrypt` shape.)
export const a1: Alg | { name: string; iv: number } = { name: "x", iv: "no" };
export const a2: Alg | { iv: number } = { name: "x", iv: "no" };
export const a3: Alg | { iv: number; q: string } = { name: "x", iv: "no" };

// …and a RIGHT `iv` is accepted even though the arm that declares it also wants
// a `q` the literal does not have: the property check passes, and the
// regularized literal then relates to `Alg`.
export const b1: Alg | { iv: number; q: string } = { name: "x", iv: 1 };
export const b2: Alg | { name: string; iv: number; q: string } = { name: "x", iv: 1 };

// The swagger shape: `name` is known only in the second arm, which rejects on
// `type`, while the first arm takes the regularized literal.
declare class S {}
type Ctor<T> = new (...args: any[]) => T;
interface Common {
  type?: Ctor<unknown> | "string" | (string & {});
}
interface Schema {
  required?: string[];
  type?: string;
  format?: string;
}
type MyOmit<T, K extends keyof any> = { [P in Exclude<keyof T, K>]: T[P] };
type Meta = Common | ({ name: string } & Common & MyOmit<Schema, "required">);
declare function api(o: Meta): void;
api({ name: "plain", type: S });

// Negative control: a property known in NO constituent is still the plain
// excess-property error.
export const c1: Alg | { iv: number } = { name: "x", nope: 1 };

// Negative control: a union with an empty-object constituent takes anything
// (`isEmptyObjectType` is `some` over a union, and the check bails on it).
export const c2: Alg | {} = { nope: 1 };
export const c3: Alg | object = { nope: 1 };
