// `as` key remapping to a computed (non-template) key.
type RenameAll<T> = { [K in keyof T as "only"]: T[K] };
interface Foo { x: number; y: string; }
declare const r: RenameAll<Foo>;
const ro: number | string = r.only;
const rbad = r.x; // TS2339 (original keys gone)

// `as K` identity remap is a no-op.
type IdRemap<T> = { [K in keyof T as K]: T[K] };
declare const i: IdRemap<Foo>;
const ix: number = i.x;
