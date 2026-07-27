// The shape a bundler's `client.d.ts` ships: a pile of overlapping wildcard
// ambient modules. `*?worker&inline` and `*.module.css` must beat `*?worker`
// and `*.css` for the specifiers they were written for, and `prefix-deep-*`
// must beat `prefix-*` — tsc picks the matching pattern with the LONGEST
// prefix, first declaration winning a tie.
declare module "*?raw" {
  const src: string;
  export default src;
}

declare module "*?worker&inline" {
  const workerConstructor: { new (): number };
  export default workerConstructor;
}

declare module "*.module.css" {
  const classes: { readonly [key: string]: string };
  export default classes;
}

declare module "*.css" {}

declare module "prefix-*" {
  export const tag: number;
}

declare module "prefix-deep-*" {
  export const tag: boolean;
}
