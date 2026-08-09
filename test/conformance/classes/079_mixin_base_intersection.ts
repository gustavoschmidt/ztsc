// `class D extends <expr>` where the expression's type is a CLASS VALUE, or an
// INTERSECTION of constructors, is the mixin spelling — and both were dropped:
// `baseExprConstructType` accepted only a plain `{ new (…): R }` object, so
// the derived class inherited no base at all.
//
// react-native declares every host component that way:
//     declare class ViewComponent extends React.Component<ViewProps> {}
//     declare const ViewBase: Constructor<NativeMethods> & typeof ViewComponent;
//     export class View extends ViewBase {}
// so `View`, `Text`, `ScrollView` and their siblings had neither `props` nor
// `NativeMethods` — TS2339 on `ref.current?.measure(…)` with a TS7006 per
// callback parameter, and no contextual type for any JSX callback attribute.

interface Methods {
  measure(cb: (x: number, y: number) => void): void;
  focus(): void;
}
type Ctor<T> = new (...args: any[]) => T;

declare class Comp {
  props: { onLayout?: (w: number) => void };
  render(): string;
}

// intersection of a mixin constructor and a class value
declare const BaseA: Ctor<Methods> & typeof Comp;
declare class A extends BaseA {
  own: number;
}
declare const a: A;
export const a1: ((w: number) => void) | undefined = a.props.onLayout;
export const a2: string = a.render();
export const a3: number = a.own;
a.measure((x, y) => x + y); // both parameters contextually typed
a.focus();

// a bare class value as the base expression
declare const BaseB: typeof Comp;
declare class B extends BaseB {}
declare const b: B;
export const b1: string = b.render();

// statics still come through the expression base
declare class WithStatic {
  static tag: string;
  inst: number;
}
declare const BaseC: Ctor<Methods> & typeof WithStatic;
declare class C extends BaseC {}
export const c1: string = C.tag;
declare const c: C;
export const c2: number = c.inst;
c.focus();

// NEGATIVES — the inherited members are typed, not `any`, and a member no
// constituent declares is still missing.
export const bad1: number = a.render();
export const bad2 = a.nope;
export const bad3: string = c.inst;
