// A failing object/array literal against a UNION target elaborates at the
// offending element/property, not at the whole literal. tsc's
// `getBestMatchIndexedAccessTypeOrUndefined` looks the element/property up on
// the union FIRST and only redirects to a single best-matching constituent
// (`getBestMatchingType`) when the union itself has no such member — so a
// union that *does* answer keeps reporting the whole literal.

interface Opts {
  count: number;
  label: string;
}

// --- redirected to the one constituent that has the property -------------

declare function objArg(o: Opts | undefined): void;
objArg({
  count: 1,
  label: 2, // error: elaborated at `label`, not at the `{`
});

const assigned: Opts | undefined = {
  count: 1,
  label: 3, // error: same, in an assignment
};

declare function arrArg(x: number[] | undefined): void;
arrArg([
  1,
  "two", // error: elaborated at the element, not at the `[`
]);

// Nested: an array of literals into `Opts[] | undefined`.
declare function nested(x: Opts[] | undefined): void;
nested([
  {
    count: 1,
    label: 4, // error: element -> property
  },
]);

// --- NOT redirected: the union answers the lookup itself -----------------

// Every constituent has `kind`, so the property target is `"a" | "b"` and the
// literal's `kind` is fine; the real failure (missing `x`) has no elaboration
// site, so the whole argument is reported.
type Shape = { kind: "a"; x: number } | { kind: "b"; y: number };
declare function shapeArg(s: Shape): void;
shapeArg({
  kind: "a",
});

// A string is indexable by number, so `("a" | "b" | ("a" | "b")[])[0]` is
// `string` and the bad element elaborates to nothing — the whole array is
// reported instead.
declare function litOrArray(x: "a" | "b" | ("a" | "b")[]): void;
litOrArray([
  "a",
  "c",
]);
