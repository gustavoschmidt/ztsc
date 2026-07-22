export {};
declare global {
  interface Widget {
    render(opts: { color: string }): string;
  }
}
