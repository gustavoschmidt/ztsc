// `keyof` of a MAPPED type is its key set, not the key domain of the index
// signature the map materializes into.
//
// tsc never asks an index signature the question: a mapped type stays a
// `MappedType` and `getIndexType` answers from `getConstraintTypeFromMappedType`,
// so `keyof Record<string, V>` is `string` and a numeric key is NOT in it. A
// WRITTEN `{ [k: string]: V }` is the other answer — `string | number`, because
// a numeric key really does read a string index signature. ztsc materializes a
// mapped type with a concrete key set into an ordinary object, so the two
// shapes would be one object; `obj_flag_mapped_keys` keeps them apart.
//
// outline writes `keyof typeof codeLanguages` for a `Record<string,
// CodeLanguage>` and hands it to `FrequencyTracker<T extends string>`.

declare const rec: Record<string, number>;
declare const recNum: Record<number, number>;
declare const recLit: Record<"a" | "b", number>;
declare const written: { [k: string]: number };
declare const both: { [k: string]: number; [k: number]: number };

declare function wantString<T extends string>(x: T): void;
declare function wantNumber<T extends number>(x: T): void;

// The key set of a `Record` over `string` is `string` alone.
export type RecKeys = keyof typeof rec;
wantString<RecKeys>("x" as RecKeys);
export const recNumericKey: RecKeys = 0;

// …over `number`, `number` alone.
wantNumber<keyof typeof recNum>(0 as keyof typeof recNum);

// …over a literal union, that union.
wantString<keyof typeof recLit>("a");

// A WRITTEN index signature keeps the `string | number` domain.
export type WrittenKeys = keyof typeof written;
export const writtenNumericKey: WrittenKeys = 0;
wantString<WrittenKeys>("x" as WrittenKeys);
wantString<keyof typeof both>("x" as keyof typeof both);

// A HOMOMORPHIC map inherits the answer from its source, either way.
export type PartialRecKeys = keyof Partial<typeof rec>;
export const partialRecNumericKey: PartialRecKeys = 0;
wantString<PartialRecKeys>("x" as PartialRecKeys);
wantString<keyof Partial<typeof written>>("x" as keyof Partial<typeof written>);

// An `as` remap names the properties itself, so the key set is the remapped one.
type Prefixed<T> = { [K in keyof T as `p${string & K}`]: T[K] };
wantString<keyof Prefixed<{ a: 1; b: 2 }>>("pa");
export const badPrefixed: keyof Prefixed<{ a: 1; b: 2 }> = "a";
