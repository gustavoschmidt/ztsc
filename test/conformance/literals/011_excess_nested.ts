interface Inner { n: number; }
interface Outer { inner: Inner; }
const o: Outer = { inner: { n: 1, extra: true } };
