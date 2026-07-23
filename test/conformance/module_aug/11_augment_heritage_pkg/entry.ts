import { Base } from "mylib";
import "mylib-plugin";

declare const x: Base;

// Own member of Base.
const a: string = x.core;
// Member added by the augmentation.
const b: boolean = x.plus;
// Member inherited by the augmentation's `extends Extra` (needs the base
// module's `Extra` to resolve inside the augmentation).
const c: number = x.extra;
// Negative control: absent everywhere → TS2339.
const d: number = x.missing;
