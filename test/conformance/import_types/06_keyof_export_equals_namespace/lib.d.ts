export = Lib;
declare namespace Lib {
    export function useRef<T>(v: T): { current: T };
    export const version: string;
}
