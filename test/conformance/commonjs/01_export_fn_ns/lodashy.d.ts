declare function _(n: number): number;
declare namespace _ {
    export function chunk(n: number): number[];
    export const VERSION: string;
    export interface Opts { a: number }
}
export = _;
