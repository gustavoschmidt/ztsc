interface Inner { n: number; }
interface Outer { inner: Inner; tag: string; }
declare const good: { inner: { n: number }; tag: string };
const a: Outer = good;
declare const bad: { inner: { n: string }; tag: string };
const b: Outer = bad;
