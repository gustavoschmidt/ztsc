// A generic template alias stays deferred until instantiated, then evaluates.
type Route<M extends string, P extends string> = `${Uppercase<M>} /${P}`;
const r1: Route<"get", "users"> = "GET /users";
const r2: Route<"post", "items"> = "POST /items";
const r3: Route<"get", "users"> = "get /users"; // wrong -> TS2322

// Deferred pattern preserved through instantiation.
type Wrap<T extends string> = `<${T}>`;
const w1: Wrap<string> = "<anything>";     // pattern accepts any middle
const w2: Wrap<"b"> = "<b>";
const w3: Wrap<"b"> = "<c>";               // wrong -> TS2322
