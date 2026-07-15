// DOM collections whose `[Symbol.iterator]` returns a DOM helper iterator
// (URLSearchParamsIterator/HeadersIterator/FormDataIterator — not on the
// esnext named-iterator list): the element type comes from the
// `next(): IteratorResult<T>` union.
const usp = new URLSearchParams("a=1");
for (const [k, v] of usp) {
  k.toUpperCase();
  v.toUpperCase();
}
for (const pair of usp) {
  const bad: string = pair; // [string, string] -> string
}
declare const h: Headers;
for (const [name, value] of h) {
  name.toUpperCase();
  value.toUpperCase();
}
declare const fd: FormData;
for (const entry of fd) {
  const bad2: number = entry; // [string, FormDataEntryValue] -> number
}
for (const key of usp.keys()) {
  key.toUpperCase();
}
