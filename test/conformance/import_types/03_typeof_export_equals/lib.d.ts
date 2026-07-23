export = Lib;
declare namespace Lib {
    export function make<T>(v: T): { value: T };
    export const VERSION: string;
}
