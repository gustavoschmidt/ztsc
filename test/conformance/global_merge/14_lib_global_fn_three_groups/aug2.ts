export {};

// Second global-scope augmentation, merged after `aug1`: the THIRD and LAST
// declaration group of `setTimeout`.
declare global {
  interface TimerB {
    __tag: "b";
  }
  function setTimeout(cb: () => void, ms?: number): TimerB;
}
