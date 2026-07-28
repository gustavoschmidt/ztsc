// `this` inside an OBJECT-LITERAL METHOD is the literal's own `this` — the
// contextual type of the literal when there is one — never the `this` of
// whatever frame happens to be walking the literal.
interface Action {
  name: string;
  checked?: (n: number) => boolean;
  perform: (n: number) => boolean;
}

declare function register(a: Action): Action;

// Contextual type `Action` supplies `this`, so the optional `checked` member
// resolves even though the literal itself is still being typed.
export const registered = register({
  name: "a",
  perform(n) {
    return this.checked!(n);
  },
  checked: (n: number) => n > 0,
});

class App {
  count: number = 0;

  ok(): Action {
    return {
      name: "b",
      perform(x) {
        return this.checked!(x);
      },
      checked: (x: number) => x > 0,
    };
  }

  // `count` is App's, not Action's: an object-literal method must NOT see the
  // enclosing class's `this`.
  leak(): Action {
    return {
      name: "c",
      perform(x) {
        return this.count > x;
      },
    };
  }

  // An ARROW in the same position keeps the lexical (class) `this`.
  arrow(): Action {
    return {
      name: "d",
      perform: (x) => this.count > x,
    };
  }
}

export const app: App = new App();
