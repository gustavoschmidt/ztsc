// A function merged with an ambient namespace: callable and property access.
declare function Widget(id: number): string;
declare namespace Widget {
  const version: string;
}
const s: string = Widget(1);
const v: string = Widget.version;
const bad: number = Widget.version;
