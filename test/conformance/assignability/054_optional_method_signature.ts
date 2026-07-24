// An optional METHOD signature (`m?(): T`) in an interface/type literal marks
// the resulting property optional, exactly like an optional property (`p?: T`).
// Regression: ztsc treated optional method-shorthand members as required, so an
// object literal omitting them failed (TS2739/2741) even though tsc accepts it.
// The canonical victim was `PropertyDescriptor` (`get?(): any; set?(v): void`),
// which made `Object.defineProperty(o, k, { value, writable })` a false TS2345.

interface Desc {
  configurable?: boolean;
  value?: any;
  get?(): any;
  set?(v: any): void;
}

// Omitting the optional methods is fine.
const a: Desc = { value: 1, configurable: true };
// Providing them is fine too.
const b: Desc = { get() { return 1; }, set(_v) {} };

// Optional generic method + accessor-adjacent shapes stay optional.
interface Bag {
  q?(): number;
  r?<K>(k: K): K;
}
const c: Bag = {};

// Negative control: a REQUIRED method still must be present.
interface Need {
  m(): void;
}
const d: Need = {};
