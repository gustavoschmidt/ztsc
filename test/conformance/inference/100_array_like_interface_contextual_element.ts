// An INTERFACE that extends `Array<T>` is array-like without being an
// `.array`: it resolves to an object carrying Array's numeric index
// signature. `contextualArrayElemType` was keyed on the type's KIND, so such a
// contextual type contributed NO element type and every element of an array
// literal widened — a fresh `{ w: 'b' }` became `{ w: string }` and stopped
// being assignable.
//
// React Native's `StyleProp<T>` is the shape that found it:
// `interface RecursiveArray<T> extends Array<T | ReadonlyArray<T> |
// RecursiveArray<T>> {}`. The plain `Array<T>` spelling of the same target was
// always fine, which is the tell.

interface AliStyle {
  w?: 'a' | 'b' | undefined;
  n?: number | undefined;
}

// The minimal form: an interface whose only content is the Array base.
interface AliPlain<T> extends Array<T> {}
declare function aliPlain(s: AliPlain<AliStyle>): void;
aliPlain([{w: 'b'}]);

// React Native's actual recursive shape.
interface AliRec<T> extends Array<T | ReadonlyArray<T> | AliRec<T>> {}
declare function aliRec(s: AliRec<AliStyle>): void;
aliRec([{w: 'b'}]);
aliRec([{w: 'b'}, {n: 1}]);

// The same through the full StyleProp union, which is how the app spells it.
type AliRegistered<T> = number & {__aliBrand: T};
type AliFalsy = undefined | null | false | '';
type AliProp<T> = T | AliRegistered<T> | AliRec<T | AliRegistered<T> | AliFalsy> | AliFalsy;
declare function aliProp(s: AliProp<AliStyle>): void;
aliProp([{w: 'b'}]);
declare const aliPre: {n: 8};
aliProp([aliPre, {w: 'b'}]);

// A plain `Array<T>` target: the control that always worked.
declare function aliArr(s: Array<AliStyle>): void;
aliArr([{w: 'b'}]);

// An interface extending Array through an intermediate interface.
interface AliMid<T> extends Array<T> {}
interface AliDeep<T> extends AliMid<T> {}
declare function aliDeep(s: AliDeep<AliStyle>): void;
aliDeep([{w: 'b'}]);

// A NON-array object with only a STRING index signature is not an array-like
// position, so its index type must NOT become an element contextual type.
// (`aliRec` above already covers the number-index case.)
declare function aliRecord(s: {[k: string]: AliStyle}): void;
declare const aliObj: {[k: string]: AliStyle};
aliRecord(aliObj);
