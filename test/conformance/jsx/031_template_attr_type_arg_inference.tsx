declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// A TEMPLATE-LITERAL attribute value feeding a string-constrained type
// parameter. `inferTypeArgs` already contextually types a template-expression
// ARGUMENT by the parameter (so `isTemplateLiteralContextualType` sees the
// constrained type variable and the expression keeps its template-literal
// type); the JSX attribute path typed the value context-free, so it widened to
// `string`, failed `TName extends Paths`, and `TName` fell back to its default
// — the whole path union. That is react-hook-form's
// `<Controller name={`owners.${i}.status`} …/>`, whose `field.value` came out
// as the union of EVERY field's value.
//
// The base-constraint half matters too: `TName extends FieldPath<TFieldValues>`
// is a deferred alias reference while `TFieldValues` is free, so the
// contextual-type test has to read the BASE constraint (tsc
// `getBaseConstraintOfType`) rather than the resolved constraint.

interface Form {
  name: string;
  owners: { status: "LEGAL" | "NOT_LEGAL" }[];
}
type Paths = "name" | "owners" | `owners.${number}` | `owners.${number}.status`;

type Val<T, P extends string> = P extends `${infer K}.${infer R}`
  ? K extends keyof T
    ? Val<T[K], R>
    : K extends `${number}`
      ? T extends ReadonlyArray<infer U>
        ? Val<U, R>
        : never
      : never
  : P extends keyof T
    ? T[P]
    : never;

declare const Ctl: <T, N extends Paths = Paths>(props: {
  name: N;
  probe?: { brand: T };
  render: (a: { value: Val<Form, N> }) => JSX.Element;
}) => JSX.Element;

declare const index: number;

// A static path resolves to the field's own type.
export const a = (
  <Ctl
    name="owners.0.status"
    render={({ value }) => {
      const s: "LEGAL" | "NOT_LEGAL" = value;
      return s as unknown as JSX.Element;
    }}
  />
);

// A template-literal path resolves the same way — the `${number}` hole survives.
export const b = (
  <Ctl
    name={`owners.${index}.status`}
    render={({ value }) => {
      const s: "LEGAL" | "NOT_LEGAL" = value;
      return s as unknown as JSX.Element;
    }}
  />
);

// NEGATIVE: the resolved field type is a real type, not a licence.
export const c = (
  <Ctl
    name={`owners.${index}.status`}
    render={({ value }) => {
      const n: number = value;
      return n as unknown as JSX.Element;
    }}
  />
);
