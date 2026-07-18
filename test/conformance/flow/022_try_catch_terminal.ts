// A try/catch where the try block and the catch block both end abruptly
// (return/throw) does not fall through — no TS2366. A `finally` that ends
// abruptly makes the whole statement terminal. A catch that can complete
// normally leaves the statement reachable.
function a(): number {
  try {
    return 1;
  } catch (e) {
    throw e;
  }
}
function b(): number {
  try {
    return 1;
  } catch {
  } finally {
    return 2;
  }
}
function c(): number {
  try {
    return 1;
  } catch {
  }
}
export { a, b, c };
