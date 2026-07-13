export {};
declare global {
  namespace NodeJS {
    interface Process {
      title: string;
    }
  }
}
