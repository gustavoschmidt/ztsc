// A homomorphic mapped type over a union source distributes, and a PRIMITIVE
// constituent maps to ITSELF — tsc's `instantiateMappedType` returns any
// constituent outside `AnyOrUnknown | InstantiableNonPrimitive | Object |
// Intersection` unchanged, which is exactly the rule the single-source path
// already follows (`Partial<string>` is `string`).
//
// ztsc distributed only when EVERY constituent was a plain object, so one
// `null` in the union sank the whole map to `{}`. kysely's
// `Simplify<ShallowDehydrateObject<O>>` is a homomorphic map, `jsonObjectFrom`
// applies it to a nullable row, and immich's `withAudioStream` therefore typed
// as `{} | null` — five TS2345 across `media.service.ts` and
// `transcoding.service.ts`.
type Info = { index: number; name: string | null };

type Dehydrate<T> = { [K in keyof T]: T[K] };

type Out = Dehydrate<Info | null>;
declare const o: Out;
export const ok: { index: number; name: string | null } | null = o;
export const bad: number = o;

// Every primitive that maps to itself, in one union.
type Wide = Dehydrate<Info | null | undefined | string | number | boolean>;
declare const w: Wide;
export const w1: Info | null | undefined | string | number | boolean = w;

// Modifiers still apply to the object half only.
type Opt = { [K in keyof Info]?: Info[K] };
type OptU = { [K in keyof (Info | null)]?: (Info | null)[K] };
declare const ou: OptU;
export const ou1: Opt | null = ou;

// A union with NO object constituent is every constituent unchanged.
type Prims = Dehydrate<string | number>;
declare const pr: Prims;
export const pr1: string | number = pr;
export const pr2: boolean = pr;

// A plain single-object source is unaffected.
type One = Dehydrate<Info>;
declare const one: One;
export const one1: number = one.index;
