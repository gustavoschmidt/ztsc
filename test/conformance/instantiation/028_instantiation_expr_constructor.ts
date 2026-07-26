interface Box<T> {
  value: T;
}

// A construct signature instantiates the same way a call signature does.
declare const BoxCtor: { new <T>(value: T): Box<T> };
const StringBox = BoxCtor<string>;
const boxed: Box<string> = new StringBox("ok");
new StringBox(1);

// A class value: the specialized constructor type is not modelled (the
// reference keeps its generic `typeof Cell`), so this stays diagnostic-free
// on both sides — the deferral under-reports, it never invents an error.
class Cell<T> {
  constructor(public value: T) {}
}
const StringCell = Cell<string>;
const cell = new StringCell("ok");
const cellValue: string = cell.value;
