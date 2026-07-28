// Bindings that are *not* loop-head elements keep the types they had.

// A bare `let` is still implicitly `any` (evolving), not an element type.
function f() {
  let acc: string = "";
  for (const it of ["a", "b"]) {
    let bare;
    bare = it;
    acc = acc + bare;
  }
  return acc;
}

// A plain `for` header's counter is typed by its own initializer.
function g() {
  let acc: number = 0;
  for (let i = 0; i < 3; i = i + 1) {
    acc = acc + i;
    const probe: null = i;
  }
  return acc;
}

// An annotated loop binding keeps the annotation, and the element type is
// still checked against it.
declare const nums: number[];
function h() {
  let acc: number = 0;
  for (const n of nums) {
    acc = acc + n;
  }
  for (const s of nums) {
    const wrong: string = s;
  }
  return acc;
}

// A non-iterable right-hand side is diagnosed once, in source order.
declare const notIterable: { a: number };
function i() {
  let acc: number = 0;
  for (const x of notIterable) {
    acc = acc + 1;
  }
  return acc;
}
