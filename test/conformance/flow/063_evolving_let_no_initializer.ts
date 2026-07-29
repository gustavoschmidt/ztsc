// `let x;` with no annotation AND no initializer is tsc's primary "auto" type:
// the declaration constrains nothing and every read takes the flow's assigned
// type. `= null` / `= undefined` (029/030) merely join that family. Without the
// initializer-less form the variable read as a plain `any` for the whole
// function, and any callback it fed lost its contextual signature.
export {};

type Item = { id: string; n: number };
declare const items: Item[];
declare const sel: string[];
declare const id: string;

// the app shape: assigned in both arms of an `if`, then read
function joined() {
  let target;
  if (sel.includes(id)) {
    target = items.filter((item) => sel.includes(item.id));
  } else {
    target = items.filter((item) => item.id === id);
  }
  // `item` is contextually typed: no TS7006
  return target.map((item) => item.n);
}

// a single assignment
function single() {
  let target;
  target = items.filter((item) => item.id === id);
  return target.map((item) => item.n);
}

// the read takes the assigned type, not `any`
function typed() {
  let n;
  n = 1;
  const bad: string = n; // TS2322 (number -> string)
}

// branches of different types join into a union
function union() {
  let v;
  if (sel.includes(id)) {
    v = 1;
  } else {
    v = "s";
  }
  const bad: boolean = v; // TS2322 (string | number -> boolean)
}

// the write itself is unchecked — that is what "does not constrain" means
function rewrite() {
  let v;
  v = 1;
  v = "s";
  const ok: string = v;
}

// an ANNOTATED declaration is not evolving, so its declared type still governs
function annotated() {
  let v: number | undefined;
  v = 1;
  const bad: string = v; // TS2322 (number -> string)
}
