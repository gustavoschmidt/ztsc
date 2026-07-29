// Negatives for contextual type arguments on a class-value `new`: the
// contextual type is evidence, never an override.

declare class CtnBox<T> {
  constructor(a?: number);
  v: T;
  read(): T;
}

// No context: the parameter stays `unknown`, it does not silently become the
// type a later use wants.
const ctnNone = new CtnBox(1);
const ctnBad1: null = ctnNone;
const ctnBad2: string = ctnNone.read();

// An argument outranks the contextual type, so a contradicting context is
// still an error.
declare class CtnPair<T> {
  constructor(a: T);
  v: T;
}
const ctnBad3: CtnPair<string> = new CtnPair(1);

// An explicit type argument outranks both.
const ctnBad4: CtnBox<string> = new CtnBox<number>(1);

// A contextual type that the class cannot satisfy at ANY instantiation is
// still rejected.
interface CtnOther {
  gone(): void;
}
const ctnBad5: CtnOther = new CtnBox(1);

// `undefined` and `null` are not object values, whatever the target's
// optionality — an all-optional target must not accept them.
interface CtnAllOpt {
  a?: string;
}
declare const ctnU: undefined;
declare const ctnN: null;
const ctnBad6: CtnAllOpt = ctnU;
const ctnBad7: CtnAllOpt = ctnN;
const ctnBad8: {} = ctnU;
const ctnBad9: Partial<CtnAllOpt> = ctnU;
