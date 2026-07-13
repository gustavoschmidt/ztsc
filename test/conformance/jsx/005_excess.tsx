declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {
    img: { src: string };
  }
}
type Props = { title: string };
declare function Card(props: Props): JSX.Element;

const a = <img src="x" alt="y" />;
const b = <Card title="t" extra="z" />;
