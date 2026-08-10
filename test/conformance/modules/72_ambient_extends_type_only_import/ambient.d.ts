// An AMBIENT class's `extends` clause is emitted nowhere, so it is not a value
// reference: a type-only import is legal there, and the base still contributes
// its members and its type argument.
import type { Base } from "./base";

export declare class Derived<T = unknown> extends Base<T> {
  replace(): void;
}
