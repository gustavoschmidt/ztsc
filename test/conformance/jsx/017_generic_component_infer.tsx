declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// A generic function component whose props carry a deferred
// mapped-over-conditional member (`_defaultValues: Partial<Defaults<T>>`,
// modelled on react-hook-form's `Control`). Without type-argument inference
// from the JSX attributes, `T` stays free: `control={control}` then relates a
// concrete `Control<Form>` against the still-generic `Control<T>` whose
// deferred member cannot relate, and the well-typed use spuriously fails
// (TS2322). Inference must resolve `T` from `control` and `N` from `name`
// (`N extends keyof T`), so the positive uses type cleanly and only the
// negative control — a `name` outside `T`'s keys — errors. That neg control is
// what proves `N` is genuinely inferred and constraint-clamped, not suppressed.

type FieldValues = Record<string, any>;
type Defaults<T> = { [K in keyof T]?: T[K] extends object ? Defaults<T[K]> : T[K] };

interface Control<T extends FieldValues> {
  _defaultValues: Partial<Defaults<T>>;
}

interface FieldProps<T extends FieldValues, N extends keyof T> {
  control: Control<T>;
  name: N;
}

declare function Field<T extends FieldValues, N extends keyof T>(p: FieldProps<T, N>): JSX.Element;

interface Form {
  sex: string;
  count: number;
}
declare const control: Control<Form>;

// Positive: `T = Form` from `control`, `N = "sex"` from `name`; props relate.
const ok = <Field control={control} name="sex" />;

// Negative control: "nope" is not a key of `Form`, so `N` clamps to
// `keyof Form` and the attribute value is rejected — TS2322.
const bad = <Field control={control} name="nope" />;
