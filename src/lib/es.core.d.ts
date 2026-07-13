// ztsc minimal ES-core lib (M10). Global-scope declarations only.
//
// Hand-written to stay STRICTLY inside ztsc's checked subset (ROADMAP §6):
// primitives, interfaces (+extends), aliases, arrays, tuples, unions,
// functions (optional/default/rest, overloads), generics (decl + inference
// from args), classes. NO conditional/mapped/template-literal types, no
// `infer`, no `keyof`-over-mapped, no `this` types, no namespaces, no
// `declare global`. Whatever does not check cleanly against tsc is trimmed
// rather than fought — the bar is a correct vertical slice, not completeness.

interface Object {}
interface Function {}
interface IArguments {}
interface Symbol {}
interface RegExp {}

interface Boolean {
    valueOf(): boolean;
}

interface Number {
    toString(radix?: number): string;
    toFixed(digits?: number): string;
    valueOf(): number;
}

interface String {
    readonly length: number;
    charAt(index: number): string;
    charCodeAt(index: number): number;
    indexOf(searchString: string): number;
    lastIndexOf(searchString: string): number;
    includes(searchString: string): boolean;
    startsWith(searchString: string): boolean;
    endsWith(searchString: string): boolean;
    slice(start?: number, end?: number): string;
    substring(start: number, end?: number): string;
    toUpperCase(): string;
    toLowerCase(): string;
    trim(): string;
    repeat(count: number): string;
    concat(...strings: string[]): string;
    split(separator: string): string[];
}

interface ReadonlyArray<T> {
    readonly length: number;
    indexOf(searchElement: T): number;
    lastIndexOf(searchElement: T): number;
    includes(searchElement: T): boolean;
    join(separator?: string): string;
    slice(start?: number, end?: number): T[];
    concat(...items: T[][]): T[];
    forEach(callbackfn: (value: T, index: number) => void): void;
    map<U>(callbackfn: (value: T, index: number) => U): U[];
    filter(callbackfn: (value: T, index: number) => boolean): T[];
    reduce(callbackfn: (previous: T, current: T, index: number) => T): T;
}

interface Array<T> {
    length: number;
    push(...items: T[]): number;
    pop(): T | undefined;
    shift(): T | undefined;
    unshift(...items: T[]): number;
    indexOf(searchElement: T): number;
    lastIndexOf(searchElement: T): number;
    includes(searchElement: T): boolean;
    join(separator?: string): string;
    reverse(): T[];
    slice(start?: number, end?: number): T[];
    concat(...items: T[][]): T[];
    forEach(callbackfn: (value: T, index: number) => void): void;
    map<U>(callbackfn: (value: T, index: number) => U): U[];
    filter(callbackfn: (value: T, index: number) => boolean): T[];
    reduce(callbackfn: (previous: T, current: T, index: number) => T): T;
    fill(value: T): T[];
}

interface Error {
    name: string;
    message: string;
    stack?: string;
}

interface Promise<T> {
    then<U>(onfulfilled: (value: T) => U): Promise<U>;
    catch(onrejected: (reason: any) => void): Promise<T>;
}

declare var console: {
    log(...data: any[]): void;
    error(...data: any[]): void;
    warn(...data: any[]): void;
    info(...data: any[]): void;
    debug(...data: any[]): void;
};

declare var Math: {
    readonly PI: number;
    readonly E: number;
    max(...values: number[]): number;
    min(...values: number[]): number;
    floor(x: number): number;
    ceil(x: number): number;
    round(x: number): number;
    trunc(x: number): number;
    abs(x: number): number;
    sign(x: number): number;
    sqrt(x: number): number;
    pow(x: number, y: number): number;
    random(): number;
};

declare var JSON: {
    stringify(value: any): string;
    parse(text: string): any;
};

declare const NaN: number;
declare const Infinity: number;

declare function parseInt(string: string, radix?: number): number;
declare function parseFloat(string: string): number;
declare function isNaN(value: number): boolean;
declare function isFinite(value: number): boolean;
