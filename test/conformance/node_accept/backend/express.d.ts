// Stand-in for @types/express: declares the Express.Request base in the
// global scope, which app code augments below.
export {};
declare global {
  namespace Express {
    interface Request {
      path: string;
      method: string;
    }
  }
}
