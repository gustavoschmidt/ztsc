declare const cb: (() => number) | undefined;
const n: number | undefined = cb?.();
const bad: number = cb?.();
