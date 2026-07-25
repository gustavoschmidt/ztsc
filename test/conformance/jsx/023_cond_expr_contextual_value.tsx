declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

interface Item {
  id: string;
  icon: 'link' | 'add' | 'edit';
}
declare function Menu(props: { items?: Item[] }): JSX.Element;

declare const cond: boolean;

// A conditional-expression attribute value forwards the prop's contextual
// type to BOTH branches, so an array/object literal in a branch is typed by
// `Item[]` and its `icon` literal is not widened to `string`.
const ok = <Menu items={cond ? [{ id: 'x', icon: 'link' }] : []} />;
const ok2 = <Menu items={cond ? [] : [{ id: 'y', icon: 'add' }]} />;

// A wrong literal in a branch is still rejected (context reaches it).
const bad = <Menu items={cond ? [{ id: 'z', icon: 'zzz' }] : []} />; // TS2322
