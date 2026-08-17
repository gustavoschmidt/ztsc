// A module declaration name is a `'`/`"` string, never a template: TS1443.
// tsc raises it from the PARSER, so it parses the template anyway —
// substitutions included, which is what keeps the body behind it from
// derailing — and, being syntactic, it silences every grammar diagnostic in
// the file behind it. That last part is a CLI-level gate this runner does not
// model, so nothing grammatical shares the file.
declare module `Templated` {
  export const d: number;
}

declare module `Sub${"stituted"}` {
  export const e: number;
}
