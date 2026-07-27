// The project's own matcher declarations: a script reopening the `jest`
// namespace's `Expect` interface. Type space still merges every contribution,
// so the winning value declaration's type carries these members too.
interface CustomMatchers {
  toBeNonNaNNumber(): void;
}

declare namespace jest {
  interface Expect extends CustomMatchers {}
}
