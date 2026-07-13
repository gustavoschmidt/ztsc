export {};
declare global {
  namespace NodeJS {
    interface ProcessEnv {
      PATH: string;
    }
    function tick(): void;
  }
}
