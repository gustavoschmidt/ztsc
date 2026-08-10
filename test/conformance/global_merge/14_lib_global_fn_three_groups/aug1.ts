export {};

// First global-scope augmentation: merged after the default library, so it is
// the SECOND declaration group of `setTimeout`.
declare global {
  interface TimerA {
    __tag: "a";
  }
  function setTimeout(cb: () => void, ms?: number): TimerA;
}
