export {};
declare global {
  namespace NodeJS {
    interface ProcessEnv {
      HOME: string;
    }
    interface Process {
      pid: number;
    }
  }
}
