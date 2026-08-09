// tsc's `getContextualTypeForChildJsxExpression`: a JSX child EXPRESSION is
// contextually typed by the `JSX.ElementChildrenAttribute` prop of the tag's
// attributes type — the same type the identical value written as an explicit
// `children={…}` attribute gets. ztsc checked children at no context at all,
// so the RENDER-PROP idiom left the arrow's parameters implicit `any`.
declare namespace JSX {
  interface Element {}
  interface ElementChildrenAttribute { children: {}; }
  interface IntrinsicElements {}
}

interface Ctx { hovered: boolean; }
type Slot = JSX.Element | string;

interface BaseProps {
  label: string;
  children: Slot | ((c: Ctx) => Slot);
}

declare function A(p: BaseProps): JSX.Element;
const a = <A label="x">{state => (state.hovered ? "y" : "n")}</A>;

// The same prop reached through Omit of an intersection (the shape a props
// type assembled out of a base component's props has).
interface Other { to: string; onPress?: () => void; }
type LinkProps = Omit<Other, "never"> & Omit<BaseProps, "label"> & { extra?: 1 };
declare function B(p: LinkProps): JSX.Element;
const b = <B to="x">{state => (state.hovered ? "y" : "n")}</B>;

// A plain intersection.
type CProps = Other & BaseProps;
declare function C(p: CProps): JSX.Element;
const c = <C to="x" label="y">{state => (state.hovered ? "y" : "n")}</C>;

// Written as an attribute instead — already worked, must keep working.
const d = <A label="x" children={state => (state.hovered ? "y" : "n")} />;
