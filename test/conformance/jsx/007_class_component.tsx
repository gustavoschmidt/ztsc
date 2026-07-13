declare namespace JSX {
  interface Element {}
  interface ElementClass { render(): void; }
  interface ElementAttributesProperty { props: {}; }
  interface IntrinsicElements {}
}
interface Props { name: string; count?: number; }
declare class Component<P> { props: P; render(): void; }
class Greeting extends Component<Props> {}

// Props of a class component come from the instance member named by
// `JSX.ElementAttributesProperty` (here `props`), i.e. `Props`.
const ok = <Greeting name="a" count={2} />;
const missing = <Greeting count={2} />;
const wrongType = <Greeting name={5} />;
const excess = <Greeting name="a" extra="z" />;
