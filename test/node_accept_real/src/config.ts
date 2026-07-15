/// <reference types="node" />
// Reads configuration from real `process.env` (typed via NodeJS.ProcessEnv's
// inherited `Dict<string>` index signature).
export interface Config {
  port: number;
  host: string;
  env: string;
}

export function loadConfig(): Config {
  const rawPort: string | undefined = process.env.PORT;
  const host: string | undefined = process.env.HOST;
  const env: string | undefined = process.env.NODE_ENV;
  return {
    port: rawPort === undefined ? 3000 : Number(rawPort),
    host: host === undefined ? "localhost" : host,
    env: env === undefined ? "development" : env,
  };
}
