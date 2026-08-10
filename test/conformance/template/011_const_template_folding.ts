// tsc EVALUATES a template expression as a compile-time constant before it
// decides between `string` and a template-literal type:
//
//   checkTemplateExpression:
//     const evaluated = node.parent.kind !== SyntaxKind.TaggedTemplateExpression
//       && evaluate(node).value;
//     if (evaluated !== undefined)
//       return getFreshTypeOfLiteralType(getStringLiteralType(evaluated));
//
// So `` const D = `feedgen|${URI}` `` — where `URI` is a `const` whose own
// initializer is a string constant — has the single string literal type
// "feedgen|at://…", not `string`, and is assignable to `` `feedgen|${string}` ``.
// Without the fold, bluesky's `usePostFeedQuery(FEED_DESC, …)` was TS2345.

type FeedDescriptor = "following" | `feedgen|${string}` | "demo";
declare function want(d: FeedDescriptor): void;

const URI = "at://did:plc:x/app.bsky.feed.generator/thevids";
const FEED_DESC = `feedgen|${URI}`;
want(FEED_DESC);

// Nested: a const whose initializer is itself a folded template.
const INNER = `did:${"plc"}:x`;
const OUTER = `feedgen|${INNER}`;
want(OUTER);

// A number constant is coerced exactly as JS does.
const N = 3;
const NEG = -2;
want(`feedgen|${N}${NEG}`);

// An enum member is a constant too (tsc's `evaluateEntityNameExpression`
// EnumMember arm).
enum E {
  A = "aa",
  N = 7,
}
want(`feedgen|${E.A}`);
want(`feedgen|${E.N}`);

// --- what must NOT fold -----------------------------------------------------
// An ANNOTATED const has no foldable initializer: `evaluateEntityNameExpression`
// requires `!declaration.type && declaration.initializer`.
declare const ANNOTATED: "abc";
const D_ANN = `feedgen|${ANNOTATED}`;
want(D_ANN);

// A `let` is not a constant variable.
let mutable = "abc";
const D_LET = `feedgen|${mutable}`;
want(D_LET);

// A call is not a constant expression.
declare function id(s: string): "abc";
const D_CALL = `feedgen|${id("abc")}`;
want(D_CALL);

// A parameter is not a constant variable either — but here the template sits
// in an argument position whose contextual type is `FeedDescriptor`, so the
// OTHER arm of `checkTemplateExpression`
// (`isTemplateLiteralContextualType(getContextualType(node))`) still gives it
// `` `feedgen|abc` ``. Constant folding and contextual templating are
// independent; this is the control that keeps them so.
export function inParam(p: "abc") {
  want(`feedgen|${p}`);
}

// The folded type is a FRESH string literal, so it still widens in a mutable
// location.
const FOLDED = `a${"b"}`;
let widened = FOLDED;
widened = "anything";

// A tagged template is excluded from the fold by tsc's own parent test; the
// tag still sees a `TemplateStringsArray`.
const tag = (s: TemplateStringsArray, ...v: unknown[]) => s.raw.length + v.length;
export const tagged = tag`feedgen|${URI}`;
