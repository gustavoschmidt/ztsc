// `this` in a TYPE position is a type VARIABLE (tsc's `thisType`), not the
// home instance. The difference only shows when the `this` is an operand of a
// DEFERRED type operator — `this["k"]`, or a conditional/alias applied to
// `this` — because resolving it eagerly demands the home interface's member
// table *while that table is still being built*, which can only answer with a
// cycle cut (`any`). Kept symbolic, the operator stays deferred until the
// access site substitutes a receiver.
//
// This is zod v4's `parse(data): output<this>` shape, where
// `output<T> = T extends { _zod: { output: any } } ? T["_zod"]["output"] : unknown`.
// Every `schema.parse(...)` / `z.infer<typeof schema>` collapsed to `any` (and
// `safeParse().data` to `unknown`), which in turn made
// `class Dto extends createZodDto(Schema) {}` an empty instance type.
type Out<T> = T extends { _zod: { output: unknown } } ? T["_zod"]["output"] : unknown;

interface SchemaBase<O> {
  _zod: { output: O };
  self(): this;
  parseC(data: unknown): Out<this>;
  parseI(data: unknown): this["_zod"]["output"];
  slot: this["_zod"];
}

interface Obj extends SchemaBase<{ crf: number }> {}

// Read through the DECLARING interface with concrete arguments...
declare const sb: SchemaBase<{ crf: number }>;
export const a1: number = sb.parseC(1).crf;
export const a2: number = sb.parseI(1).crf;
export const a3: number = sb.slot.output.crf;

// ...and through a derived one, where a bare `this` still tracks the receiver.
declare const o: Obj;
export const b0: Obj = o.self();
export const b1: number = o.parseC(1).crf;
export const b2: number = o.parseI(1).crf;
export const b3: number = o.slot.output.crf;

// Type-level indexed access: `Obj["parseC"]` must read `this` as `Obj`, the
// receiver the access names — tsc gets this by resolving a reference's members
// with the reference itself as `thisArgument`.
type PC = Obj["parseC"];
declare const pc: PC;
export const c1: number = pc(1).crf;
type R = ReturnType<Obj["parseI"]>;
declare const r: R;
export const c2: number = r.crf;

// The mixin-base form: `class X extends <value whose construct signature
// returns ReturnType<T["parse"]>>`.
interface Dto<T extends { parseC(data: unknown): unknown }> {
  new (): ReturnType<T["parseC"]>;
}
declare const D: Dto<Obj>;
export class F extends D {}
declare const f: F;
export const d1: number = f.crf;

// A `this["k"]` annotation written INSIDE the class body still admits the
// concrete member type: the deferred access relates through its constraint,
// which for a `this` marker is the home instance.
export class K {
  _zod!: { output: number };
  m(): this["_zod"] {
    return this._zod;
  }
}

// Negatives: the resolved types are precise, not `any`.
export const n1: string = o.parseC(1).crf;
export const n2: string = sb.parseI(1).crf;
export const n3: string = f.crf;
export const n4: number = o.parseC(1).nope;
