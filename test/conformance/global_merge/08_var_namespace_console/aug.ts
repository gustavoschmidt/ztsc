// Mimics @types/node augmenting the lib.dom `console`: a `namespace console`
// merged onto lib.dom's `var console: Console`. The merged value must stay
// `Console`, not collapse to the (member-less) namespace object
// (`typeof console`), or every `console.<method>` access is a phantom TS2339.
export {};
declare global {
  namespace console {
    interface Options {
      color: boolean;
    }
  }
}
