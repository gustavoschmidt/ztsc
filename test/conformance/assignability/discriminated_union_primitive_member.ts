// tsc runs `typeRelatedToDiscriminatedType` on
// `extractTypesOfKind(target, Object | Intersection | Substitution)`, not on
// the whole union. A PRIMITIVE constituent has no properties, so leaving it in
// makes every candidate discriminant fail the "present on every member" test
// and the by-cases split never runs at all.
//
// react-navigation's `Link`'s `to` prop is `LinkProps<ParamList> | string`,
// and that lone `string` is what stopped
// `to={{ screen: cond ? 'CustomFeed' : 'ProfileList', params }}` from being
// split -- a source whose `screen` is a two-literal union fits neither screen
// constituent on its own.

type Params = { name: string; rkey: string };

type Props =
  | ({ href?: string } & { screen: 'CustomFeed'; params: Params })
  | ({ href?: string } & { screen: 'ProfileList'; params: Params })
  | ({ href?: string } & { screen: 'Home'; params?: undefined });

declare const p: Params;

export function go(cond: boolean) {
  // With the `string` constituent present, and without it.
  const a: Props | string = { screen: cond ? 'CustomFeed' : 'ProfileList', params: p };
  const b: Props = { screen: cond ? 'CustomFeed' : 'ProfileList', params: p };

  // A case the object members do not cover still reports -- the `string`
  // constituent does not rescue an object source.
  const c: Props | string = { screen: cond ? 'CustomFeed' : 'Nope', params: p }; // TS2322

  // `Home` takes no params, so the split across it fails on the payload.
  const d: Props | string = { screen: cond ? 'CustomFeed' : 'Home', params: p }; // TS2322

  return [a, b, c, d];
}
