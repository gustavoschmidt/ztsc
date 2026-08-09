// tsc's `getApparentType` maps the `object` KEYWORD onto `globalObjectType`,
// so it carries the same `Object.prototype` members every object type does.
// ztsc gave `object` no members at all, and the standard
// `typeof v === "object" && v !== null && v.constructor === Object` shape
// (used to detect a plain empty object) was a false TS2339.

declare const o: object;

export const ctor: Function = o.constructor;
export const str: string = o.toString();
export const has: boolean = o.hasOwnProperty("a");
export const val: Object = o.valueOf();

declare const value: unknown;
export function isEmptyPlainObject(): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    Object.keys(value).length === 0 &&
    value.constructor === Object
  );
}

// NEGATIVE — only the apparent members, nothing else.
export const bad = o.zzqq;
