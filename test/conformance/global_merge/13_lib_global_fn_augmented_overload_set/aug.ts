export {};

// A global-scope augmentation of two functions the default library already
// declares. tsc merges the augmentation's declarations into the existing
// global symbol AFTER every plain global file, so these come LAST in
// declaration order and FIRST in overload-resolution order.
declare global {
  interface Timer {
    __tag: "timer";
  }
  function setTimeout(cb: () => void, ms?: number): Timer;
  function clearTimeout(timer: Timer): void;
}
