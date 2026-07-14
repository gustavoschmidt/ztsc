// Inference FROM a template-literal pattern binds `infer` holes.
type Head<S> = S extends `${infer H}-${infer _R}` ? H : never;
const h1: Head<"a-b-c"> = "a";       // lazy: first delimiter
const h2: Head<"a-b-c"> = "b";       // wrong -> TS2322

type Tail<S> = S extends `${infer _H}-${infer R}` ? R : never;
const t1: Tail<"a-b-c"> = "b-c";

type StripGet<S> = S extends `get${infer R}` ? R : never;
const g1: StripGet<"getName"> = "Name";

// Multi-delimiter split.
type Three<S> = S extends `${infer A}.${infer B}.${infer C}` ? [A, B, C] : never;
const m1: Three<"x.y.z"> = ["x", "y", "z"];
const m2: Three<"x.y.z"> = ["x", "y", "w"]; // wrong -> TS2322
