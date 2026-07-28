export interface Action {
  name: string;
  checked?: () => boolean;
  perform: () => boolean;
}

export declare function register(a: Action): Action;

// `this` here is the literal's contextual type `Action`, whoever asks for
// `act`'s type first — including a class body in another file.
export const act = register({
  name: "a",
  perform() {
    return this.checked!();
  },
  checked: () => true,
});
