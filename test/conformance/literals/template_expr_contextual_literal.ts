// tsc's `checkTemplateExpression`: a template EXPRESSION keeps a
// template-literal type (instead of widening to `string`) when it is in a
// const context or when `isTemplateLiteralContextualType` holds of its
// contextual type -- `TypeFlags.StringLiteral | TypeFlags.TemplateLiteral`.
// The STRING-LITERAL half is what makes a template over a literal union land
// on a literal-union target, which is how react-navigation's tab dispatch
// (`navigation.navigate(`${tab}Tab`)`) type-checks at all.
//
// Each hole contributes its own type only when it is assignable to
// `templateConstraintType` (`string | number | bigint | boolean | null |
// undefined`); anything else contributes `string`.

type Tab = 'Home' | 'Search';
type Route = 'HomeTab' | 'SearchTab' | 'Other';

declare function nav(x: Route): void;
declare function withName(o: { name: Route }): void;

export function dispatch(tab: Tab, n: number, o: object) {
  // Contextual type is a union of string literals: the template stays a
  // template and expands to `"HomeTab" | "SearchTab"`.
  nav(`${tab}Tab`);
  withName({ name: `${tab}Tab` });
  const a: Route = `${tab}Tab`;
  const arr: Route[] = [`${tab}Tab`];

  // A SINGLE string-literal contextual type fires the rule too -- and then
  // reports, because the expansion is wider than the target.
  const b: 'HomeTab' = `${tab}Tab`; // TS2322

  // A template-literal contextual type fires it as well.
  const c: `${string}Tab` = `${tab}Tab`;

  // No template-literal contextual type: the expression is `string`.
  const d = `${tab}Tab`;
  const e: Route = d; // TS2322
  const f: string = `${tab}Tab`;

  // A `number` hole is spellable but not enumerable: the result is a pattern.
  const g: '1Tab' | '2Tab' = `${n}Tab`; // TS2322

  // An `object` hole is NOT assignable to `templateConstraintType`, so it
  // contributes `string` -- `` `${string}Tab` ``, which the pattern accepts.
  const h: `${string}Tab` = `${o}Tab`;

  return [a, arr, b, c, d, e, f, g, h];
}
