interface Listener { handle(x: string | number): void; }
declare const narrow: { handle(x: string): void };
const l: Listener = narrow;
