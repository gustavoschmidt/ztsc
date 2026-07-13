export {};
declare global {
  interface String {
    shout(): string;
  }
}
const a: string = "x".shout();
const b: number = "x".shout();
const n: number = "x".length;
