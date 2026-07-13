// App-owned augmentation: the classic backend `globals.d.ts` that reopens
// Express.Request and NodeJS.ProcessEnv to add project-specific fields.
export {};
declare global {
  namespace Express {
    interface Request {
      user?: string;
    }
  }
  namespace NodeJS {
    interface ProcessEnv {
      NODE_ENV: string;
    }
  }
}
