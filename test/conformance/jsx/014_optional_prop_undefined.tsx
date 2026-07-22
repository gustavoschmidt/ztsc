declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}
type Props = { date?: Date; label: string };
declare function DatePicker(props: Props): JSX.Element;

declare const maybe: Date | undefined;
declare const def: Date;
declare const maybeStr: string | undefined;

// Optional prop admits `undefined`: `date?: Date` accepts a `Date | undefined`
// value — no error.
const a = <DatePicker date={maybe} label="x" />;

// Optional prop with a concrete value — no error.
const b = <DatePicker date={def} label="y" />;

// Required prop still rejects `undefined`: `label: string` given
// `string | undefined` is TS2322 (negative control).
const c = <DatePicker date={def} label={maybeStr} />;
