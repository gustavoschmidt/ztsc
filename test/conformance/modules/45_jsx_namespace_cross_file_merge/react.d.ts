// A JSX runtime's declarations: a MODULE that augments the global `JSX`
// namespace from inside `declare global`.
declare global {
  namespace JSX {
    interface Element {}
    interface IntrinsicElements {
      div: { id?: string };
      span: { id?: string };
    }
  }
}

export declare const version: number;
