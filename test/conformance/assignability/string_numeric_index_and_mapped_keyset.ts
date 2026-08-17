// A string-like primitive's index infos come off its apparent type `String`,
// whose only one is `readonly [index: number]: string` — so a string
// satisfies a numeric index signature whose value type accepts `string`, and
// fails one that does not.
declare var anyIdx: { [index: number]: any };
anyIdx = "foo";
anyIdx = false; // Error

declare var strIdx: { [index: number]: string };
strIdx = "foo";

declare var numIdx: { [index: number]: number };
numIdx = "foo"; // Error

// The same rule is what makes a string literal a `String`.
var strObj: String = "string";
var numObj: Number = 123;
var boolObj: Boolean = true;

// A template-literal type and a string-transform intrinsic are string-like
// too.
declare var tpl: `a${string}`;
anyIdx = tpl;
declare var up: Uppercase<string>;
anyIdx = up;

// A map whose template is the source indexed by the map's whole KEY SET is
// the identity on that source: every key it produces is a key of `S`, and the
// value it gives is the union of all of `S`'s values.
type MyMap<T> = { [P in keyof T]: T[keyof T] };
function f1<U>(arg: U): MyMap<U> {
  return arg;
}

type Thing = { a: string; b: number };
function f2(x: Thing): MyMap<Thing> {
  return x;
}

// A key set the source does not cover produces a required key the source
// cannot supply.
type Widened<T extends { a: string; b: string }> = {
  [P in "a" | "b"]: T["a" | "b"];
};
function f3<U extends { a: string; b: string }>(arg: Pick<U, "a">): Widened<U> {
  return arg; // Error
}
