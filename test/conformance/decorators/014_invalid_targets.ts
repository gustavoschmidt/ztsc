// A decorator is only ever valid on a class or on a member of one. Under TC39
// standard decorators the rejected shapes are:
//
//   * every statement-position declaration that is not a class — the run is
//     judged against whatever follows it, and `export`/`declare`/`abstract`
//     between the `@` and the `class` are transparent;
//   * a constructor, a class index signature and a `static {}` block;
//   * an `abstract` or `declare` field, and a get/set accessor with no body;
//   * a method OVERLOAD, which gets its own wording (TS1249).
//
// A run of several decorators reports ONCE, on its first `@`.
declare function dec<T>(target: T): T;

@dec
var v: number;
@dec
enum E { A }
@dec
interface I {}
@dec
type T = number;
@dec
namespace N {
  export var y: number;
}
@dec
function f() {}
@dec @dec
let l = 1;
namespace M {
  @dec
  import Y = N.y;
}

// Legal: the decorator reaches the class behind the modifiers.
@dec
class Ok {}
@dec
export class Ok2 {}
@dec
declare class Ok3 {}
@dec
abstract class Ok4 {}

abstract class C {
  @dec constructor() {}
  @dec [key: string]: unknown;
  @dec static {}
  @dec abstract field: number;
  @dec declare declared: number;
  @dec abstract get g(): number;
  @dec over(): void;
  over(): void {}
}
