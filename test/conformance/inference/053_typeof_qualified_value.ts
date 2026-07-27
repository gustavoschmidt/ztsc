// A type query on a QUALIFIED entity name (`typeof A.b`) names a value, so its
// type is property `b` on the type of `A` — for a namespace member, a nested
// namespace, a class static, or a plain object property alike. Anything but a
// bare identifier (or `typeof import("m").x`) used to fall through to `any`,
// which erased every type derived from it: a component library that builds its
// props from `ComponentPropsWithoutRef<typeof Primitive.div>` lost the whole
// props shape, so every attribute written on such a component read as excess.
declare function use(x: unknown): void;

declare namespace NS {
  const n: number;
  const s: string;
  namespace Inner {
    const flag: boolean;
  }
}

const a: string = null as unknown as typeof NS.n;
const b: number = null as unknown as typeof NS.s;
const c: number = null as unknown as typeof NS.Inner.flag;

// Through a value whose type is a mapped type: the member must be looked up on
// the resolved mapping, not given up on.
type Keys = "div" | "span";
interface Box<E> {
  tag: E;
}
declare const Boxes: { [E in Keys]: Box<E> };
declare const d: typeof Boxes.div;
const d1: "div" = d.tag;
const d2: "span" = d.tag;

// Class statics.
declare class C {
  static make(): number;
  static readonly label: string;
}
const e: string = null as unknown as ReturnType<typeof C.make>;
const f: number = null as unknown as typeof C.label;

// A generic instantiated through the query still carries its argument.
declare const g: typeof Boxes.span;
use(g.tag);
const h: "div" = g.tag;

export { a, b, c, d1, d2, e, f, h };
