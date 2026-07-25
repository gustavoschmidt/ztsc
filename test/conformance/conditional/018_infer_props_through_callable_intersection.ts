// A conditional-type `infer` over a function pattern must reach the call
// signature of a callable that is an INTERSECTION of a bare function with an
// object of statics — the shape `typeof f` takes for a `declare function`
// carrying own properties (e.g. React's `Icon` = `((props) => JSX) & typeof
// Icon`). Without descending the bare `.function` member, `infer P` yields
// `unknown` (so `ComponentProps<typeof Icon>['name']` collapsed to unknown).
type ReactNode = {} | null | undefined | boolean | number | string;
interface Component<P, S> {}
interface ReactElement {
  type: any;
  props: any;
}
type JSXElementConstructor<P> =
  | ((props: P, ctx?: any) => ReactNode)
  | (new (props: P, ctx?: any) => Component<any, any>);
type ComponentProps<T extends JSXElementConstructor<any>> = T extends JSXElementConstructor<
  infer P
>
  ? P
  : {};

interface IconProps {
  name: 'a' | 'b';
  size?: number;
}

// A callable INTERSECTION: a bare call signature `& { …statics }`.
type IconLike = ((props: IconProps) => ReactElement) & { displayName?: string };

type Props = ComponentProps<IconLike>; // IconProps
type NameT = ComponentProps<IconLike>['name']; // 'a' | 'b'

const nOk: NameT = 'a';
const nBad: NameT = 'zzz'; // TS2322
const pOk: Props = { name: 'b' };
const pBad: Props = { name: 'zzz' }; // TS2322
