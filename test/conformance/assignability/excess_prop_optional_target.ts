// tsc's `isKnownProperty` ends in `return false`: only an OBJECT type (or a
// union/intersection that recurses into one) can know a property name. A
// `null`/`undefined`/`void`/`never` constituent knows nothing.
//
// That matters for every OPTIONAL parameter and property, because under
// `strictNullChecks` its type is `X | undefined`. Treating the `undefined`
// constituent as knowing every name switched the excess-property check off
// wholesale for optional targets — React's
// `cloneElement(el, props?: Partial<P> & Attributes)` silently accepted a
// `style` property tsc rejects. (In an OVERLOAD set the missing diagnostic
// also cost the TS2769 its anchor: the last candidate's re-check had nothing
// to point at, so the error landed on the callee rather than on the offending
// property.)

interface Attributes {
  key?: string | null;
}

declare function optionalParam(props?: Attributes): void;
optionalParam({ style: 1 });

declare function requiredParam(props: Attributes): void;
requiredParam({ style: 1 });

interface Holder {
  opts?: Attributes;
}
const h: Holder = { opts: { style: 1 } };

// A nullable target is the same shape.
declare function nullableParam(props: Attributes | null): void;
nullableParam({ style: 1 });

// Positive control: a known property is still fine through the same optional
// targets, and `undefined` itself is still a legal argument.
optionalParam({ key: "k" });
optionalParam(undefined);
optionalParam();
const h2: Holder = { opts: { key: "k" } };

// An empty-object constituent still switches the whole check off, exactly as
// tsc's `isEmptyObjectType` union rule (`some`) says.
declare function emptyish(props?: Attributes | {}): void;
emptyish({ style: 1 });

export { h, h2 };
