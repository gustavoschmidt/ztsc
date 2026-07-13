declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}
type Props = { name: string; count?: number };
declare function Greeting(props: Props): JSX.Element;

const ok = <Greeting name="a" count={2} />;
const missing = <Greeting count={2} />;
const wrongType = <Greeting name={5} />;
const undef = <Unknown />;
