// The project's own custom elements: a SCRIPT declaring the same global `JSX`
// namespace. It merges with the runtime's — it does not replace it, so the
// intrinsic elements from both are in scope.
declare namespace JSX {
  interface IntrinsicElements {
    "em-emoji": { name?: string };
  }
}
