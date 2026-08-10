// A namespace whose members are published by `export { … }` specifiers rather
// than by declarations in its own body — both of an IMPORTED name and of a
// file-local one. tsc reads such a specifier as an export of the namespace, in
// every meaning the aliased entity has.
import { Emitter, Shape } from "./emitter";

class Local {
  local(): number {
    return 1;
  }
}

declare namespace Api {
  export { Emitter };
  export { Shape };
  export { Local as Renamed };
}

export { Api };
