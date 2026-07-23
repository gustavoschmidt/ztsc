// A homomorphic mapped type (`{ [P in keyof T]: … }`) distributes over a union
// source: `Readonly<A | B>` === `Readonly<A> | Readonly<B>`. Distilled from
// react-pdf, whose class components read `props: Readonly<P>` with
// `P = ImageProps = ImageWithSrcProp | ImageWithSourceProp`; before the fix the
// union source fell through to `{}`, so every attribute read as excess.
interface WithSrc {
  id?: string;
  src: string;
}
interface WithSource {
  id?: string;
  source: string;
}
type ImageProps = WithSrc | WithSource;
type RO = Readonly<ImageProps>;

// each arm's required member is accepted through the distributed union.
const a: RO = { id: "1", src: "s" }; // ok — matches Readonly<WithSrc>
const b: RO = { source: "s" }; // ok — matches Readonly<WithSource>

// negative control: an object matching NEITHER arm is still rejected.
const c: RO = { id: "1" }; // TS2322: neither src nor source present

// the readonly modifier is applied by the map.
const w: RO = { src: "s" };
w.src = "t"; // TS2540: src is read-only
