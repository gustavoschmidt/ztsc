// Object-literal arguments to an OVERLOADED signature are contextually typed
// by the candidate's parameter type, so a fresh `{ k: 'lit' }` keeps its
// string-literal property types instead of widening to `string`. Without the
// contextual parameter the widened `string` fails against a literal-union
// target (`Intl.DateTimeFormat`'s `month?: "short" | …`, turf's
// `units?: "meters" | …`), spuriously rejecting every overload. The
// single-signature path already types args by the parameter; overload probing
// must match it.

interface Opts {
  size?: "short" | "long";
  units?: "meters" | "kilometers";
  label?: string;
}

// Two overloads: the string-locale overload should accept the literal props.
declare function fmt(loc: string | string[], o?: Opts): string;
declare function fmt(loc: number, o?: Opts): string;

fmt("pt", { size: "short" }); // ok: literal "short" kept, matches union
fmt("pt", { units: "meters" }); // ok
fmt("pt", { size: "long", units: "kilometers", label: "x" }); // ok
fmt("pt", {}); // ok: empty options
fmt("pt"); // ok: options omitted

// Merged construct signatures (the Intl constructor shape): the object-literal
// options must survive across the merged overload set.
interface KCtor {
  new (loc?: string | string[], o?: Opts): object;
}
interface KCtor {
  new (loc?: string, o?: Opts): object;
}
declare const K: KCtor;
new K("pt", { size: "short" }); // ok

// Negative control: a property value outside the literal union rejects every
// overload (proves the argument is really related, not blindly accepted, and
// that literals are not simply erased to `string`).
fmt("pt", { size: "medium" }); // error TS2769

// (Excess-property rejection during overload probing — tsc rejects
// `fmt("pt", { bogus: 1 })` with TS2769 — is a separate pre-existing
// under-report: ztsc's candidate test uses plain assignability, and an
// all-optional target admits extra properties. Not exercised here.)

// Negative control: single-signature path unchanged — a bad literal errors with
// the ordinary argument diagnostic, not a no-overload wrapper.
declare function one(o: Opts): void;
one({ size: "medium" }); // error TS2322
