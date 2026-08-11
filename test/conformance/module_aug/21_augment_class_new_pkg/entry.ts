import { Widget, makeWidget } from "mylib";
import "mylib-plugin";

// A constructed instance IS the augmented type: assignable to the annotation
// the augmentation folded into, and carrying the augmented member.
export function fromNew(): Widget {
  return new Widget("c");
}
export function fromFactory(): Widget {
  return makeWidget();
}
const extra: number = new Widget("c").extra;
const core: string = new Widget("c").core;

// A subclass built on the class symbol sees the augmentation too.
class Sub extends Widget {
  own = 1;
}
export function fromSub(): Widget {
  return new Sub("c");
}
const subExtra: number = new Sub("c").extra;

// …and the merge adds nothing that was not declared.
const bad: string = new Widget("c").extra;
new Widget("c").absentXyz;

export { extra, core, subExtra, bad };
