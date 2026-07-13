declare module "fs" {
  export function readFileSync(path: string): string;
  export const sep: string;
}
