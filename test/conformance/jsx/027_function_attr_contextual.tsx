declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

declare function use(x: unknown): void;

interface Props {
  onPick?: (v: number) => void;
  onDrop: (a: string, b: boolean) => void;
}
declare function A(props: Props): JSX.Element;

// A function-valued attribute (arrow or function expression) is contextually
// typed by the target prop's signature, so its parameters get their types from
// the callback type instead of raising TS7006 (implicit any).
const ok1 = <A onPick={(v) => use(v)} onDrop={(a, b) => use(a)} />;
const ok2 = <A onPick={function (v) { use(v); }} onDrop={function (a, b) { use(b); }} />;

// The contextual type really flows: a parameter is the annotated type, not any.
const ok3 = <A onPick={(v) => { const n: number = v; use(n); }} onDrop={(a, b) => { const s: string = a; const t: boolean = b; use(s); use(t); }} />;

// Fewer parameters than the target signature is allowed (function assignability).
const ok4 = <A onDrop={() => use(0)} />;

// A wrong explicit parameter type is still rejected.
const bad1 = <A onDrop={(a: number, b: boolean) => use(a)} />; // TS2322

// A wrong return type is still rejected.
declare function B(props: { pick: (v: number) => string }): JSX.Element;
const bad2 = <B pick={(v) => v} />; // TS2322

// Extra parameters beyond the target signature are still rejected.
const bad3 = <A onPick={(v: number, extra: string) => use(v)} onDrop={(a, b) => use(a)} />; // TS2322

// Contextual typing through a generic component: the type argument is inferred
// from the non-function attribute, then the callback is typed by it.
declare function List<T>(props: { items: T[]; onSelect: (item: T) => void }): JSX.Element;
const ok5 = <List items={[1, 2, 3]} onSelect={(item) => { const n: number = item; use(n); }} />;
const bad4 = <List items={['a']} onSelect={(item) => { const n: number = item; use(n); }} />; // TS2322
