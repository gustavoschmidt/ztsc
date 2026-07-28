import { act } from "./dep";

// Resolving `registry`'s declared type demands `act`'s type from dep.ts while
// this class's own `this` is in force. That ambient `this` must not follow the
// demand across the file boundary: `App` has no `checked`, and dep.ts's object
// literal must still see `Action`.
class App {
  count: number = 0;
  registry: typeof act = act;

  bump(): number {
    return this.count + 1;
  }
}

export const app: App = new App();
export const bad: string = app.count;
