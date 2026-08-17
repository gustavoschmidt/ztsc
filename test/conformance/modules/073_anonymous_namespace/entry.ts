// `module { … }` / `namespace { … }` — a namespace declaration with NO NAME
// is TS1437, reported on the `{`. tsc parses it anyway (its name node is
// simply missing), so the body still parses and its declarations still bind;
// nothing else in the file is disturbed.
module {
  export var foo = 1;

  module {
    export var bar = 1;
  }

  var bar = 2;
}

declare namespace {
  class Named {
    n: number;
  }
}

const use: number = new Named().n;
