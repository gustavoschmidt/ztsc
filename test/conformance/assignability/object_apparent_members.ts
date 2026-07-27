// Every object type carries the apparent members of the global `Object`
// interface — the tail of tsc's `getPropertyOfType`
// (`return getPropertyOfObjectType(globalObjectType, name)`). Without it
// `({} as { x: number }).hasOwnProperty("x")` was TS2339.
interface Object {
  hasOwnProperty(v: string): boolean;
  ztscMarker(): number;
}

declare const o: { x: number };
const a: boolean = o.hasOwnProperty('x');
const b: number = o.ztscMarker();
const c: number = o.hasOwnProperty('x'); // TS2322
const d = o.notAMember; // TS2339

// Interfaces and class instances too.
interface Named {
  n: string;
}
declare const i: Named;
const e: boolean = i.hasOwnProperty('n');

class K {
  k: number = 1;
}
declare const k: K;
const f: number = k.ztscMarker();

// The apparent members are NOT the object's own: an object literal that
// supplies one is still an excess property against a target that does not
// declare it.
declare function takesX(v: { x: number }): void;
takesX({ x: 1, ztscMarker: () => 1 }); // TS2353
