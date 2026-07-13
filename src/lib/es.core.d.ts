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
    at(index: number): string | undefined;
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
    trimStart(): string;
    trimEnd(): string;
    padStart(targetLength: number, padString?: string): string;
    padEnd(targetLength: number, padString?: string): string;
    repeat(count: number): string;
    replace(searchValue: string, replaceValue: string): string;
    replaceAll(searchValue: string, replaceValue: string): string;
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
    find(predicate: (value: T, index: number) => boolean): T | undefined;
    findIndex(predicate: (value: T, index: number) => boolean): number;
    some(predicate: (value: T, index: number) => boolean): boolean;
    every(predicate: (value: T, index: number) => boolean): boolean;
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
    find(predicate: (value: T, index: number) => boolean): T | undefined;
    findIndex(predicate: (value: T, index: number) => boolean): number;
    some(predicate: (value: T, index: number) => boolean): boolean;
    every(predicate: (value: T, index: number) => boolean): boolean;
    sort(compareFn?: (a: T, b: T) => number): T[];
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

// Map/Set/Date carry constructors, so they are declared as classes: `new` on a
// var-typed object needs a construct signature (`new (...): T`), which is out of
// ztsc's subset. A `declare class` gives the same instance surface plus a usable
// `new`, and type-checks identically to tsc's interface + *Constructor pairing
// for the common (non-iterator) operations.
declare class Map<K, V> {
    constructor();
    readonly size: number;
    get(key: K): V | undefined;
    set(key: K, value: V): Map<K, V>;
    has(key: K): boolean;
    delete(key: K): boolean;
    clear(): void;
    forEach(callbackfn: (value: V, key: K) => void): void;
}

declare class Set<T> {
    constructor();
    readonly size: number;
    add(value: T): Set<T>;
    has(value: T): boolean;
    delete(value: T): boolean;
    clear(): void;
    forEach(callbackfn: (value: T) => void): void;
}

declare class Date {
    constructor();
    getTime(): number;
    getFullYear(): number;
    getMonth(): number;
    getDate(): number;
    getHours(): number;
    getMinutes(): number;
    getSeconds(): number;
    toISOString(): string;
    toString(): string;
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

// Constructor-side statics. These merge (by name) with the same-named type
// declarations above (interface Object/Number/String, interface Array<T>),
// mirroring tsc's `interface Foo` + `declare var Foo: FooConstructor` split.
declare var Object: {
    keys(o: any): string[];
    values(o: any): any[];
    entries(o: any): [string, any][];
    assign(target: any, ...sources: any[]): any;
    freeze<T>(o: T): T;
};

declare var Array: {
    isArray(arg: any): boolean;
    of<T>(...items: T[]): T[];
};

declare var Number: {
    isInteger(value: any): boolean;
    isFinite(value: any): boolean;
    isNaN(value: any): boolean;
    parseInt(string: string, radix?: number): number;
    parseFloat(string: string): number;
    readonly MAX_SAFE_INTEGER: number;
    readonly MIN_SAFE_INTEGER: number;
    readonly MAX_VALUE: number;
    readonly MIN_VALUE: number;
    readonly EPSILON: number;
};

declare var String: {
    fromCharCode(...codes: number[]): string;
};

declare var Promise: {
    resolve<T>(value: T): Promise<T>;
    reject(reason?: any): Promise<any>;
    all<T>(values: T[]): Promise<T[]>;
};

declare const NaN: number;
declare const Infinity: number;

declare function parseInt(string: string, radix?: number): number;
declare function parseFloat(string: string): number;
declare function isNaN(value: number): boolean;
declare function isFinite(value: number): boolean;
