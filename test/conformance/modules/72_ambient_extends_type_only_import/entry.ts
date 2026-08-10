import type { Derived } from "./ambient";
import type { Base } from "./base";

declare const d: Derived<string>;

// Inherited members and the base type argument both survive.
d.replace();
d.release();
const t: string | undefined = d.tag;

// The derived instance relates to the base its hierarchy declares.
const b: Base<string> = d;
b.release();

// NEGATIVE: still a real member set, not `any`.
d.notAMember();

// A `declare class` in a .ts file is ambient too.
declare class DeclaredHere<T = unknown> extends Base<T> {
  other(): void;
}
declare const dh: DeclaredHere<number>;
dh.release();
const u: number | undefined = dh.tag;

// NEGATIVE: a NON-ambient class's extends clause IS emitted code, so a
// type-only import there is TS1361.
class Concrete extends Base<string> {
  more(): void {}
}
export const c = new Concrete();
