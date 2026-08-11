// A `this` parameter whose type is an INTERSECTION carrying a construct
// signature — `this: Something & { new (): M }` — infers `M` from the receiver
// class value.
//
// ztsc's intersection-parameter inference pairs a parameter constituent with an
// argument constituent of the same KIND (so a brand object never infers from
// the tuple beside it). A class value is `.class_value`, a nominal shortcut with
// no structure of its own, so it matched no constituent at all: `M` took no
// candidate and fell back to its constraint. Every `User.findOne()` came back a
// bare `Model`, and every property read off the result a TS2339.
//
// sequelize's `ModelStatic<M>` is exactly this shape:
//   type ModelStatic<M extends Model> = NonConstructor<typeof Model> & { new (): M };
//   static findOne<M extends Model>(this: ModelStatic<M>): M | null;
class Model {
  static bare<M extends Model>(this: { new (): M }): M | null {
    return null;
  }
  static after<M extends Model>(this: { tag: string } & { new (): M }): M | null {
    return null;
  }
  static before<M extends Model>(this: { new (): M } & { tag: string }): M | null {
    return null;
  }
  // The construct signature and the companion members on ONE constituent, the
  // other a decoration that says nothing about `M`.
  static wide<M extends Model>(this: { new (): M; tag: string } & { other: number }): M | null {
    return null;
  }
  static tag = "m";
  static other = 1;
  id = "";
}

class User extends Model {
  email = "";
}

// `M` is `User` in every form.
export const u1: string | undefined = User.bare()?.email;
export const u2: string | undefined = User.after()?.email;
export const u3: string | undefined = User.before()?.email;
export const u4: string | undefined = User.wide()?.email;

// …and the inferred instance type is not the base.
export const n1: User | null = User.after();
export const n2: number = User.after(); // TS2322

// A subclass of the subclass, and the base itself.
class Admin extends User {
  level = 1;
}
export const a1: number | undefined = Admin.after()?.level;
export const a2: string = Model.after()?.id ?? "";
export const a3 = Model.after()?.email; // TS2339 (`Model` has no `email`)
