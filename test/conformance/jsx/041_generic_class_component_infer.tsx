// A GENERIC class component gets its type arguments inferred from its JSX
// attributes, exactly as a generic function component does. tsc resolves
// `<C …/>` as a call against `typeof C`'s construct signatures
// (`resolveJsxOpeningLikeElement`), so the class's own type parameters are the
// signature's; `getJsxPropsTypeForSignatureFromMember` then reads the props
// member off the signature's RETURN — the instantiated instance type.
//
// ztsc bailed out of `jsxClassComponentProps` whenever the class had type
// parameters, which left the whole attributes target UNKNOWN — not merely
// `ItemT = any` — so every callback attribute lost its contextual type.
// react-native's lists are this shape (`class FlatList<ItemT = any> extends
// FlatListComponent<ItemT, FlatListProps<ItemT>>`), and both
// `keyExtractor={(item, index) => …}` and the inherited, entirely
// non-generic `onScroll={e => …}` reported TS7006 on each parameter.
declare namespace JSX {
  interface Element {}
  interface ElementClass {
    render(): void;
  }
  interface ElementAttributesProperty {
    props: {};
  }
  interface IntrinsicElements {}
}
declare class Component<P> {
  constructor(props: P);
  props: Readonly<P>;
  render(): void;
}

interface ScrollProps {
  onScroll?: ((e: { x: number }) => void) | undefined;
}
interface ListProps<ItemT> extends ScrollProps {
  data?: ReadonlyArray<ItemT> | null | undefined;
  keyExtractor?: ((item: ItemT, index: number) => string) | undefined;
}
declare abstract class ListBase<ItemT, P> extends Component<P> {
  scrollToItem: (p: { item: ItemT }) => void;
}
declare class List<ItemT = any> extends ListBase<ItemT, ListProps<ItemT>> {}

declare const images: { thumb: string }[];

// `ItemT` is inferred from `data`, so both callbacks are contextually typed:
// the generic one and the one inherited from a non-generic base.
export const ok = (
  <List
    data={images}
    keyExtractor={(item, index) => item.thumb + index}
    onScroll={e => {
      const x: number = e.x;
      return x;
    }}
  />
);

// Negative control: `item` really is the element type, not `any`.
export const bad = (
  <List data={images} keyExtractor={(item, index) => item.nope + index} />
);

// An explicit type argument wins over inference.
export const exp = (
  <List<{ thumb: string }>
    data={images}
    keyExtractor={item => item.thumb}
  />
);

// With nothing to infer from, the parameter falls back to its default (`any`
// here), and the attributes are still checked against the props type.
export const dflt = <List keyExtractor={(item, index) => String(index)} />;
export const excess = <List data={images} nope={1} />;
