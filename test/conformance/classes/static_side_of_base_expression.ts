// `class D extends <expression>` inherits the base expression's own members
// on its STATIC side, exactly as it inherits a base class's statics. tsc gives
// the class's static type the base CONSTRUCTOR type as its base type, so
// anything declared beside the construct signature is reachable through `D.`.
//
// ztsc folded a base into the static side only when the `extends` clause
// resolved to a class SYMBOL, so the mixin/factory form inherited nothing.
// nestjs-zod is written that way — `class Dto extends createZodDto(Schema) {}`,
// where `ZodDto` declares `create(input)`, `schema` and `isZodDto` next to its
// `new ()` — and immich calls `HlsPlaylistHeaderDto.create(headers)` and reads
// `PluginManifestDto.schema` (four keys, one of them the TS7006 cascade off a
// callback whose parameter lost its contextual type).
interface Row {
  id: string;
  n: number;
}

interface Factory {
  new (): Row;
  create(input: unknown): Row;
  schema: { name: string };
  isFactory: true;
}

declare function makeFactory(name: string): Factory;

class Dto extends makeFactory('row') {
  own = 1;
}

// The statics come through…
export const c1: Row = Dto.create({});
export const c2: string = Dto.schema.name;
export const c3: true = Dto.isFactory;

// …and are typed, not `any`.
export const c4: number = Dto.schema.name;

// The instance side still comes from the construct signature's return, plus
// the class's own members.
declare const d: Dto;
export const i1: string = d.id;
export const i2: number = d.own;
export const i3: number = d.missing;

// A static declared on the class itself wins over the inherited one.
class Dto2 extends makeFactory('row') {
  static isFactory: true = true;
  static extra = 7;
}
export const c5: true = Dto2.isFactory;
export const c5b: number = Dto2.extra;
export const c5c: string = Dto2.schema.name;

// A further subclass keeps reaching it.
class Dto3 extends Dto {}
export const c6: string = Dto3.schema.name;

// Constructing the derived class does not pick up an extra signature.
export const n1: Dto = new Dto();
export const n2: Dto = new Dto(1);
