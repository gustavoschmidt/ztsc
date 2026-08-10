import { Api } from "./globals";

// The member as a TYPE, with type arguments.
declare const e: Api.Emitter<string>;
e.release();
const t: string | undefined = e.tag;

// A re-exported interface is a type too.
declare const sh: Api.Shape;
const n: number = sh.n;

// The member as a VALUE: a type query over the namespace-qualified name, then
// an instantiation of it.
declare const Ctor: typeof Api.Emitter;
const made = new Ctor<string>();
made.release();

// NEGATIVE: the aliased class's real member set is reachable, so a bogus
// member is still an error rather than degrading to `any`.
made.notAMember();

// A renamed specifier publishes only the new name.
declare const r: Api.Renamed;
const m: number = r.local();

// NEGATIVE: the local name is not an export of the namespace.
declare const bad: Api.Local;

// A class may extend the namespace-qualified value.
class Derived extends Ctor<string> {
  extra(): number {
    return 2;
  }
}
const d = new Derived();
d.release();
const q: number = d.extra();
