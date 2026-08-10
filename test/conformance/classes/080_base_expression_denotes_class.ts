// tsc's `resolveBaseTypesOfClass` takes the NOMINAL route whenever the base
// expression's type has a class symbol — `baseConstructorType.symbol &&
// baseConstructorType.symbol.flags & SymbolFlags.Class` — and only falls back
// to "return type of a construct signature" for a genuine mixin/factory base.
// A `const` whose declared type is a class's static side denotes that class,
// so `class D extends TheConst<Arg>` has base `TheClass<Arg>`.
//
// ztsc resolved that shape through the construct signature instead, whose
// return type still mentions the base's own unbound parameter, so every member
// inherited through it came back `any`. `expo-modules-core` publishes its whole
// hierarchy this way (`export declare const SharedObject: typeof
// ExpoGlobal.SharedObject` beside a same-named type alias), so `expo-video`'s
// `class VideoPlayer extends SharedObject<VideoPlayerEvents>` carried
// `_TEventsMap_DONT_USE_IT?: any` instead of the events map — and every
// `useEventListener(player, 'timeUpdate', evt => …)` lost the contextual
// listener type its `TEventsMap` inference hangs on (TS7006 on `evt`).
type EventsMap = Record<string, (...args: any[]) => void>;

declare class Emitter<T extends EventsMap = Record<never, never>> {
  marker?: T;
  addListener<K extends keyof T>(name: K, listener: T[K]): void;
}
declare class SharedBase<
  T extends EventsMap = Record<never, never>,
> extends Emitter<T> {
  release(): void;
}
declare namespace Global {
  export { SharedBase };
}

// The published shape: a type alias merged with a const, both spelled as a
// type query on the namespace-exported class.
type Shared<T extends EventsMap = Record<never, never>> = typeof Global.SharedBase<T>;
declare const Shared: typeof Global.SharedBase;

type MyEvents = {
  tick(payload: { at: number }): void;
  done(): void;
};

declare class Player extends Shared<MyEvents> {
  duration: number;
}
declare const p: Player;

// The events map reaches the derived class through TWO levels of heritage…
export const m1: MyEvents | undefined = p.marker;
export const m2: number = p.marker;

// …so the method that reads it is typed, not `any`.
p.addListener('tick', evt => {
  const n: number = evt.at;
  return n;
});
p.addListener('nope', () => {});

// The class's own and inherited members are unaffected.
export const d1: number = p.duration;
export const d2: string = p.duration;
p.release();

// A base whose type query is written without the namespace behaves the same.
declare const Direct: typeof SharedBase;
declare class Player2 extends Direct<MyEvents> {}
declare const p2: Player2;
export const m3: number = p2.marker;

// A genuine factory base (no class symbol behind it) still takes the
// construct-signature route.
declare const Factory: { new (): { made: string } };
class Made extends Factory {}
export const f1: string = new Made().made;
export const f2: number = new Made().made;
