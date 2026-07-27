export {};
declare global {
  var appName: string;
  const appVersion: number;
  function greet(who: string): string;
  class AppClass {
    z: number;
  }
  namespace appNs {
    const count: number;
  }
  interface AppShape {
    n: number;
  }
  // A value whose own type mentions the global scope object: the shape
  // lib.dom uses for `declare var window: Window & typeof globalThis`.
  var appHost: AppShape & typeof globalThis;
}
