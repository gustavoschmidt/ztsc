interface Box { inner?: { value: number }; }
function f(b: Box): number {
  if (b.inner) { return b.inner.value; }
  return 0;
}
