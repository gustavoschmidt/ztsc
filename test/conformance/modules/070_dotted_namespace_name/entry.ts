// A DOTTED namespace name is sugar for nesting: `namespace A.B.C { … }`
// declares `A`, whose member is `B`, whose member is `C`, which holds the
// body — and every segment but the outermost is an EXPORT of the one before
// it, so the whole chain is reachable from outside.
//
// `module` spells the same thing, `declare` makes the one shared body ambient
// however many segments precede it, and a segment may be a contextual keyword.
namespace A.B.C {
  export const x = 1;
  export interface Shape {
    side: number;
  }
}

module M.N {
  export function f(): string {
    return "";
  }
}

declare namespace D.E {
  const z: number;
  namespace Inner {
    const w: string;
  }
}

export namespace Out.In {
  export const v = true;
}

const n: number = A.B.C.x;
const bad: string = A.B.C.x;
const s: A.B.C.Shape = { side: 1 };
const t: string = M.N.f();
const u: number = D.E.z;
const q: string = D.E.Inner.w;
const r: boolean = Out.In.v;
