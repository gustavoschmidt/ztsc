// A directive only suppresses the line the diagnostic is ANCHORED at, so the
// anchor is what decides whether `@ts-expect-error` over the offending PROPERTY
// of an object-literal argument does anything.
//
// The oracle anchors a present-but-mismatched property at the property itself
// (`elaborateObjectLiteral`, and the elaboration REPLACES the top-level
// TS2345), so the directive lands on it and the whole call is silent. Anchoring
// at the argument's `{` instead — one line higher — leaves the report standing,
// which is what a hand-written mock object in a test file looks like: outline's
// `server/middlewares/authentication.test.ts` puts the directive on the mocked
// `request:` property fifteen times over.
export {};

interface Ctx {
  url: string;
  method: string;
  request: { get(k: string): string };
}
declare function handle(c: Ctx & { extra?: 1 }): void;

// Suppressed: the report is anchored on line 26, which the directive covers.
handle({
  url: "",
  method: "",
  // @ts-expect-error mock request
  request: { get: 1 as unknown as number },
});

// Still suppressed when the literal is ALSO missing properties — the
// elaboration replaces the missing-property report rather than adding to it.
handle({
  // @ts-expect-error mock request
  request: { get: 1 as unknown as number },
});

// The control: a literal that is only MISSING properties has nothing to
// elaborate, so its report stays at the ARGUMENT and only a directive over the
// call reaches it. Undirected first (line 39), then suppressed.
handle({
  url: "",
});
// @ts-expect-error missing method and request
handle({
  url: "",
});
