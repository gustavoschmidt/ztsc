declare namespace JSX {
  interface Element {}
  interface ElementClass { render(): void; }
  interface ElementAttributesProperty { props: {}; }
  interface IntrinsicAttributes { key?: string | number; }
  interface IntrinsicClassAttributes<T> { ref?: ((instance: T | null) => void) | { current: T | null } | null; }
  interface IntrinsicElements {}
}
interface Props { name: string; }
declare class Component<P> { props: P; render(): void; }
class Box extends Component<Props> { focus(): void {} }

declare const boxRef: { current: Box | null };
declare const cb: (instance: Box | null) => void;

// A CLASS component's attributes target is
// `IntrinsicAttributes & IntrinsicClassAttributes<Box> & Props`, so `ref`
// is an allowed attribute even though it is not part of `Props`.
const ok = <Box name="a" ref={boxRef} />;
const okCallback = <Box name="a" ref={cb} />;
const okNull = <Box name="a" ref={null} />;
// The `ref` VALUE is still checked against `IntrinsicClassAttributes<Box>`.
declare const wrongRef: { current: string | null };
const bad = <Box name="a" ref={wrongRef} />;
// `ref` does not make an unrelated excess attribute legal.
const excess = <Box name="a" ref={boxRef} zzz={1} />;
