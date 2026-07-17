// A conditional type used as a function-type parameter annotation must parse:
// `(value: V extends number ? number : V) => void`. ztsc's function-type
// speculation previously suppressed conditional parsing everywhere under the
// `spec` guard, truncating the annotation at `extends` and derailing the parse.
type Fn<V> = (value: V extends number ? number : V, tag: string) => void;
interface Box<V extends number | string = number | string> {
  onChange?: Fn<V>;
  label?: string;
}
type B = Box<number | string>;
const ok1: B = { label: "hi" };
const ok2: B = { onChange: (v, t) => {} };
