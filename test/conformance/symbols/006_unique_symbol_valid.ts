const k: unique symbol = Symbol();
const o = { [k]: 1 };
const v: number = o[k];
declare const d: unique symbol;
class C {
  static readonly s: unique symbol = Symbol();
}
interface I { readonly x: unique symbol; }
type T = { readonly m: unique symbol };
