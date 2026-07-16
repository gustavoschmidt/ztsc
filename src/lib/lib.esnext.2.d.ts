
interface ReadonlyArray<T> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: T, fromIndex?: number): boolean;
}

interface Int8Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

interface Uint8Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

interface Uint8ClampedArray<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

interface Int16Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

interface Uint16Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

interface Int32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

interface Uint32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

interface Float32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

interface Float64Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;
}

//========== lib.es2016.intl.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


declare namespace Intl {
    /**
     * The `Intl.getCanonicalLocales()` method returns an array containing
     * the canonical locale names. Duplicates will be omitted and elements
     * will be validated as structurally valid language tags.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/getCanonicalLocales)
     *
     * @param locale A list of String values for which to get the canonical locale names
     * @returns An array containing the canonical and validated locale names.
     */
    function getCanonicalLocales(locale?: string | readonly string[]): string[];
}

//========== lib.es2016.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2015" />
/// <reference lib="es2016.array.include" />
/// <reference lib="es2016.intl" />

//========== lib.es2017.arraybuffer.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface ArrayBufferConstructor {
    new (): ArrayBuffer;
}

//========== lib.es2017.date.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface DateConstructor {
    /**
     * Returns the number of milliseconds between midnight, January 1, 1970 Universal Coordinated Time (UTC) (or GMT) and the specified date.
     * @param year The full year designation is required for cross-century date accuracy. If year is between 0 and 99 is used, then year is assumed to be 1900 + year.
     * @param monthIndex The month as a number between 0 and 11 (January to December).
     * @param date The date as a number between 1 and 31.
     * @param hours Must be supplied if minutes is supplied. A number from 0 to 23 (midnight to 11pm) that specifies the hour.
     * @param minutes Must be supplied if seconds is supplied. A number from 0 to 59 that specifies the minutes.
     * @param seconds Must be supplied if milliseconds is supplied. A number from 0 to 59 that specifies the seconds.
     * @param ms A number from 0 to 999 that specifies the milliseconds.
     */
    UTC(year: number, monthIndex?: number, date?: number, hours?: number, minutes?: number, seconds?: number, ms?: number): number;
}

//========== lib.es2017.intl.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


declare namespace Intl {
    interface DateTimeFormatPartTypesRegistry {
        day: any;
        dayPeriod: any;
        era: any;
        hour: any;
        literal: any;
        minute: any;
        month: any;
        second: any;
        timeZoneName: any;
        weekday: any;
        year: any;
    }

    type DateTimeFormatPartTypes = keyof DateTimeFormatPartTypesRegistry;

    interface DateTimeFormatPart {
        type: DateTimeFormatPartTypes;
        value: string;
    }

    interface DateTimeFormat {
        formatToParts(date?: Date | number): DateTimeFormatPart[];
    }
}

//========== lib.es2017.object.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface ObjectConstructor {
    /**
     * Returns an array of values of the enumerable own properties of an object
     * @param o Object that contains the properties and methods. This can be an object that you created or an existing Document Object Model (DOM) object.
     */
    values<T>(o: { [s: string]: T; } | ArrayLike<T>): T[];

    /**
     * Returns an array of values of the enumerable own properties of an object
     * @param o Object that contains the properties and methods. This can be an object that you created or an existing Document Object Model (DOM) object.
     */
    values(o: {}): any[];

    /**
     * Returns an array of key/values of the enumerable own properties of an object
     * @param o Object that contains the properties and methods. This can be an object that you created or an existing Document Object Model (DOM) object.
     */
    entries<T>(o: { [s: string]: T; } | ArrayLike<T>): [string, T][];

    /**
     * Returns an array of key/values of the enumerable own properties of an object
     * @param o Object that contains the properties and methods. This can be an object that you created or an existing Document Object Model (DOM) object.
     */
    entries(o: {}): [string, any][];

    /**
     * Returns an object containing all own property descriptors of an object
     * @param o Object that contains the properties and methods. This can be an object that you created or an existing Document Object Model (DOM) object.
     */
    getOwnPropertyDescriptors<T>(o: T): { [P in keyof T]: TypedPropertyDescriptor<T[P]>; } & { [x: string]: PropertyDescriptor; };
}

//========== lib.es2017.sharedmemory.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2015.symbol" />
/// <reference lib="es2015.symbol.wellknown" />

interface SharedArrayBuffer {
    /**
     * Read-only. The length of the ArrayBuffer (in bytes).
     */
    readonly byteLength: number;

    /**
     * Returns a section of an SharedArrayBuffer.
     */
    slice(begin?: number, end?: number): SharedArrayBuffer;
    readonly [Symbol.toStringTag]: "SharedArrayBuffer";
}

interface SharedArrayBufferConstructor {
    readonly prototype: SharedArrayBuffer;
    new (byteLength?: number): SharedArrayBuffer;
    readonly [Symbol.species]: SharedArrayBufferConstructor;
}
declare var SharedArrayBuffer: SharedArrayBufferConstructor;

interface ArrayBufferTypes {
    SharedArrayBuffer: SharedArrayBuffer;
}

interface Atomics {
    /**
     * Adds a value to the value at the given position in the array, returning the original value.
     * Until this atomic operation completes, any other read or write operation against the array
     * will block.
     */
    add(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number, value: number): number;

    /**
     * Stores the bitwise AND of a value with the value at the given position in the array,
     * returning the original value. Until this atomic operation completes, any other read or
     * write operation against the array will block.
     */
    and(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number, value: number): number;

    /**
     * Replaces the value at the given position in the array if the original value equals the given
     * expected value, returning the original value. Until this atomic operation completes, any
     * other read or write operation against the array will block.
     */
    compareExchange(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number, expectedValue: number, replacementValue: number): number;

    /**
     * Replaces the value at the given position in the array, returning the original value. Until
     * this atomic operation completes, any other read or write operation against the array will
     * block.
     */
    exchange(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number, value: number): number;

    /**
     * Returns a value indicating whether high-performance algorithms can use atomic operations
     * (`true`) or must use locks (`false`) for the given number of bytes-per-element of a typed
     * array.
     */
    isLockFree(size: number): boolean;

    /**
     * Returns the value at the given position in the array. Until this atomic operation completes,
     * any other read or write operation against the array will block.
     */
    load(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number): number;

    /**
     * Stores the bitwise OR of a value with the value at the given position in the array,
     * returning the original value. Until this atomic operation completes, any other read or write
     * operation against the array will block.
     */
    or(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number, value: number): number;

    /**
     * Stores a value at the given position in the array, returning the new value. Until this
     * atomic operation completes, any other read or write operation against the array will block.
     */
    store(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number, value: number): number;

    /**
     * Subtracts a value from the value at the given position in the array, returning the original
     * value. Until this atomic operation completes, any other read or write operation against the
     * array will block.
     */
    sub(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number, value: number): number;

    /**
     * If the value at the given position in the array is equal to the provided value, the current
     * agent is put to sleep causing execution to suspend until the timeout expires (returning
     * `"timed-out"`) or until the agent is awoken (returning `"ok"`); otherwise, returns
     * `"not-equal"`.
     */
    wait(typedArray: Int32Array<ArrayBufferLike>, index: number, value: number, timeout?: number): "ok" | "not-equal" | "timed-out";

    /**
     * Wakes up sleeping agents that are waiting on the given index of the array, returning the
     * number of agents that were awoken.
     * @param typedArray A shared Int32Array<ArrayBufferLike>.
     * @param index The position in the typedArray to wake up on.
     * @param count The number of sleeping agents to notify. Defaults to +Infinity.
     */
    notify(typedArray: Int32Array<ArrayBufferLike>, index: number, count?: number): number;

    /**
     * Stores the bitwise XOR of a value with the value at the given position in the array,
     * returning the original value. Until this atomic operation completes, any other read or write
     * operation against the array will block.
     */
    xor(typedArray: Int8Array<ArrayBufferLike> | Uint8Array<ArrayBufferLike> | Int16Array<ArrayBufferLike> | Uint16Array<ArrayBufferLike> | Int32Array<ArrayBufferLike> | Uint32Array<ArrayBufferLike>, index: number, value: number): number;

    readonly [Symbol.toStringTag]: "Atomics";
}

declare var Atomics: Atomics;

//========== lib.es2017.string.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface String {
    /**
     * Pads the current string with a given string (repeated and/or truncated, if needed) so that the resulting string has a given length.
     * The padding is applied from the start of the current string.
     *
     * [MDN](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/padStart)
     *
     * @param targetLength The length of the resulting string once the current `str` has been padded.
     *        If the value is less than or equal to `str.length`, then `str` is returned as-is.
     *
     * @param padString The string to pad the current `str` with.
     *        If `padString` is too long to stay within `targetLength`, it will be truncated from the end.
     *        The default value is the space character (U+0020).
     */
    padStart(targetLength: number, padString?: string): string;

    /**
     * Pads the current string with a given string (repeated and/or truncated, if needed) so that the resulting string has a given length.
     * The padding is applied from the end of the current string.
     *
     * [MDN](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/padEnd)
     *
     * @param targetLength The length of the resulting string once the current `str` has been padded.
     *        If the value is less than or equal to `str.length`, then `str` is returned as-is.
     *
     * @param padString The string to pad the current `str` with.
     *        If `padString` is too long to stay within `targetLength`, it will be truncated from the end.
     *        The default value is the space character (U+0020).
     */
    padEnd(targetLength: number, padString?: string): string;
}

//========== lib.es2017.typedarrays.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface Int8ArrayConstructor {
    new (): Int8Array<ArrayBuffer>;
}

interface Uint8ArrayConstructor {
    new (): Uint8Array<ArrayBuffer>;
}

interface Uint8ClampedArrayConstructor {
    new (): Uint8ClampedArray<ArrayBuffer>;
}

interface Int16ArrayConstructor {
    new (): Int16Array<ArrayBuffer>;
}

interface Uint16ArrayConstructor {
    new (): Uint16Array<ArrayBuffer>;
}

interface Int32ArrayConstructor {
    new (): Int32Array<ArrayBuffer>;
}

interface Uint32ArrayConstructor {
    new (): Uint32Array<ArrayBuffer>;
}

interface Float32ArrayConstructor {
    new (): Float32Array<ArrayBuffer>;
}

interface Float64ArrayConstructor {
    new (): Float64Array<ArrayBuffer>;
}

//========== lib.es2017.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2016" />
/// <reference lib="es2017.arraybuffer" />
/// <reference lib="es2017.date" />
/// <reference lib="es2017.intl" />
/// <reference lib="es2017.object" />
/// <reference lib="es2017.sharedmemory" />
/// <reference lib="es2017.string" />
/// <reference lib="es2017.typedarrays" />

//========== lib.es2018.asynciterable.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2015.symbol" />
/// <reference lib="es2015.iterable" />

interface SymbolConstructor {
    /**
     * A method that returns the default async iterator for an object. Called by the semantics of
     * the for-await-of statement.
     */
    readonly asyncIterator: unique symbol;
}

interface AsyncIterator<T, TReturn = any, TNext = any> {
    // NOTE: 'next' is defined using a tuple to ensure we report the correct assignability errors in all places.
    next(...[value]: [] | [TNext]): Promise<IteratorResult<T, TReturn>>;
    return?(value?: TReturn | PromiseLike<TReturn>): Promise<IteratorResult<T, TReturn>>;
    throw?(e?: any): Promise<IteratorResult<T, TReturn>>;
}

interface AsyncIterable<T, TReturn = any, TNext = any> {
    [Symbol.asyncIterator](): AsyncIterator<T, TReturn, TNext>;
}

/**
 * Describes a user-defined {@link AsyncIterator} that is also async iterable.
 */
interface AsyncIterableIterator<T, TReturn = any, TNext = any> extends AsyncIterator<T, TReturn, TNext> {
    [Symbol.asyncIterator](): AsyncIterableIterator<T, TReturn, TNext>;
}

/**
 * Describes an {@link AsyncIterator} produced by the runtime that inherits from the intrinsic `AsyncIterator.prototype`.
 */
interface AsyncIteratorObject<T, TReturn = unknown, TNext = unknown> extends AsyncIterator<T, TReturn, TNext> {
    [Symbol.asyncIterator](): AsyncIteratorObject<T, TReturn, TNext>;
}

//========== lib.es2018.asyncgenerator.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2018.asynciterable" />

interface AsyncGenerator<T = unknown, TReturn = any, TNext = any> extends AsyncIteratorObject<T, TReturn, TNext> {
    // NOTE: 'next' is defined using a tuple to ensure we report the correct assignability errors in all places.
    next(...[value]: [] | [TNext]): Promise<IteratorResult<T, TReturn>>;
    return(value: TReturn | PromiseLike<TReturn>): Promise<IteratorResult<T, TReturn>>;
    throw(e: any): Promise<IteratorResult<T, TReturn>>;
    [Symbol.asyncIterator](): AsyncGenerator<T, TReturn, TNext>;
}

interface AsyncGeneratorFunction {
    /**
     * Creates a new AsyncGenerator object.
     * @param args A list of arguments the function accepts.
     */
    new (...args: any[]): AsyncGenerator;
    /**
     * Creates a new AsyncGenerator object.
     * @param args A list of arguments the function accepts.
     */
    (...args: any[]): AsyncGenerator;
    /**
     * The length of the arguments.
     */
    readonly length: number;
    /**
     * Returns the name of the function.
     */
    readonly name: string;
    /**
     * A reference to the prototype.
     */
    readonly prototype: AsyncGenerator;
}

interface AsyncGeneratorFunctionConstructor {
    /**
     * Creates a new AsyncGenerator function.
     * @param args A list of arguments the function accepts.
     */
    new (...args: string[]): AsyncGeneratorFunction;
    /**
     * Creates a new AsyncGenerator function.
     * @param args A list of arguments the function accepts.
     */
    (...args: string[]): AsyncGeneratorFunction;
    /**
     * The length of the arguments.
     */
    readonly length: number;
    /**
     * Returns the name of the function.
     */
    readonly name: string;
    /**
     * A reference to the prototype.
     */
    readonly prototype: AsyncGeneratorFunction;
}

//========== lib.es2018.promise.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/**
 * Represents the completion of an asynchronous operation
 */
interface Promise<T> {
    /**
     * Attaches a callback that is invoked when the Promise is settled (fulfilled or rejected). The
     * resolved value cannot be modified from the callback.
     * @param onfinally The callback to execute when the Promise is settled (fulfilled or rejected).
     * @returns A Promise for the completion of the callback.
     */
    finally(onfinally?: (() => void) | undefined | null): Promise<T>;
}

//========== lib.es2018.regexp.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface RegExpMatchArray {
    groups?: {
        [key: string]: string;
    };
}

interface RegExpExecArray {
    groups?: {
        [key: string]: string;
    };
}

interface RegExp {
    /**
     * Returns a Boolean value indicating the state of the dotAll flag (s) used with a regular expression.
     * Default is false. Read-only.
     */
    readonly dotAll: boolean;
}

//========== lib.es2018.intl.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


declare namespace Intl {
    // http://cldr.unicode.org/index/cldr-spec/plural-rules#TOC-Determining-Plural-Categories
    type LDMLPluralRule = "zero" | "one" | "two" | "few" | "many" | "other";
    type PluralRuleType = "cardinal" | "ordinal";

    interface PluralRulesOptions {
        localeMatcher?: "lookup" | "best fit" | undefined;
        type?: PluralRuleType | undefined;
        minimumIntegerDigits?: number | undefined;
        minimumFractionDigits?: number | undefined;
        maximumFractionDigits?: number | undefined;
        minimumSignificantDigits?: number | undefined;
        maximumSignificantDigits?: number | undefined;
    }

    interface ResolvedPluralRulesOptions {
        locale: string;
        pluralCategories: LDMLPluralRule[];
        type: PluralRuleType;
        minimumIntegerDigits: number;
        minimumFractionDigits: number;
        maximumFractionDigits: number;
        minimumSignificantDigits?: number;
        maximumSignificantDigits?: number;
    }

    interface PluralRules {
        resolvedOptions(): ResolvedPluralRulesOptions;
        select(n: number): LDMLPluralRule;
    }

    interface PluralRulesConstructor {
        new (locales?: string | readonly string[], options?: PluralRulesOptions): PluralRules;
        (locales?: string | readonly string[], options?: PluralRulesOptions): PluralRules;
        supportedLocalesOf(locales: string | readonly string[], options?: { localeMatcher?: "lookup" | "best fit"; }): string[];
    }

    const PluralRules: PluralRulesConstructor;

    interface NumberFormatPartTypeRegistry {
        literal: never;
        nan: never;
        infinity: never;
        percent: never;
        integer: never;
        group: never;
        decimal: never;
        fraction: never;
        plusSign: never;
        minusSign: never;
        percentSign: never;
        currency: never;
    }

    type NumberFormatPartTypes = keyof NumberFormatPartTypeRegistry;

    interface NumberFormatPart {
        type: NumberFormatPartTypes;
        value: string;
    }

    interface NumberFormat {
        formatToParts(number?: number | bigint): NumberFormatPart[];
    }
}

//========== lib.es2018.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2017" />
/// <reference lib="es2018.asynciterable" />
/// <reference lib="es2018.asyncgenerator" />
/// <reference lib="es2018.promise" />
/// <reference lib="es2018.regexp" />
/// <reference lib="es2018.intl" />

//========== lib.es2019.array.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


type FlatArray<Arr, Depth extends number> = {
    done: Arr;
    recur: Arr extends ReadonlyArray<infer InnerArr> ? FlatArray<InnerArr, [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20][Depth]>
        : Arr;
}[Depth extends -1 ? "done" : "recur"];

interface ReadonlyArray<T> {
    /**
     * Calls a defined callback function on each element of an array. Then, flattens the result into
     * a new array.
     * This is identical to a map followed by flat with depth 1.
     *
     * @param callback A function that accepts up to three arguments. The flatMap method calls the
     * callback function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the callback function. If
     * thisArg is omitted, undefined is used as the this value.
     */
    flatMap<U, This = undefined>(
        callback: (this: This, value: T, index: number, array: T[]) => U | ReadonlyArray<U>,
        thisArg?: This,
    ): U[];

    /**
     * Returns a new array with all sub-array elements concatenated into it recursively up to the
     * specified depth.
     *
     * @param depth The maximum recursion depth
     */
    flat<A, D extends number = 1>(
        this: A,
        depth?: D,
    ): FlatArray<A, D>[];
}

interface Array<T> {
    /**
     * Calls a defined callback function on each element of an array. Then, flattens the result into
     * a new array.
     * This is identical to a map followed by flat with depth 1.
     *
     * @param callback A function that accepts up to three arguments. The flatMap method calls the
     * callback function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the callback function. If
     * thisArg is omitted, undefined is used as the this value.
     */
    flatMap<U, This = undefined>(
        callback: (this: This, value: T, index: number, array: T[]) => U | ReadonlyArray<U>,
        thisArg?: This,
    ): U[];

    /**
     * Returns a new array with all sub-array elements concatenated into it recursively up to the
     * specified depth.
     *
     * @param depth The maximum recursion depth
     */
    flat<A, D extends number = 1>(
        this: A,
        depth?: D,
    ): FlatArray<A, D>[];
}

//========== lib.es2019.object.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2015.iterable" />

interface ObjectConstructor {
    /**
     * Returns an object created by key-value entries for properties and methods
     * @param entries An iterable object that contains key-value entries for properties and methods.
     */
    fromEntries<T = any>(entries: Iterable<readonly [PropertyKey, T]>): { [k: string]: T; };

    /**
     * Returns an object created by key-value entries for properties and methods
     * @param entries An iterable object that contains key-value entries for properties and methods.
     */
    fromEntries(entries: Iterable<readonly any[]>): any;
}

//========== lib.es2019.string.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface String {
    /** Removes the trailing white space and line terminator characters from a string. */
    trimEnd(): string;

    /** Removes the leading white space and line terminator characters from a string. */
    trimStart(): string;

    /**
     * Removes the leading white space and line terminator characters from a string.
     * @deprecated A legacy feature for browser compatibility. Use `trimStart` instead
     */
    trimLeft(): string;

    /**
     * Removes the trailing white space and line terminator characters from a string.
     * @deprecated A legacy feature for browser compatibility. Use `trimEnd` instead
     */
    trimRight(): string;
}

//========== lib.es2019.symbol.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface Symbol {
    /**
     * Expose the [[Description]] internal slot of a symbol directly.
     */
    readonly description: string | undefined;
}

//========== lib.es2019.intl.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


declare namespace Intl {
    interface DateTimeFormatPartTypesRegistry {
        unknown: never;
    }
}

//========== lib.es2019.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2018" />
/// <reference lib="es2019.array" />
/// <reference lib="es2019.object" />
/// <reference lib="es2019.string" />
/// <reference lib="es2019.symbol" />
/// <reference lib="es2019.intl" />

//========== lib.es2020.intl.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2018.intl" />
declare namespace Intl {
    /**
     * A string that is a valid [Unicode BCP 47 Locale Identifier](https://unicode.org/reports/tr35/#Unicode_locale_identifier).
     *
     * For example: "fa", "es-MX", "zh-Hant-TW".
     *
     * See [MDN - Intl - locales argument](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#locales_argument).
     */
    type UnicodeBCP47LocaleIdentifier = string;

    /**
     * Unit to use in the relative time internationalized message.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/format#Parameters).
     */
    type RelativeTimeFormatUnit =
        | "year"
        | "years"
        | "quarter"
        | "quarters"
        | "month"
        | "months"
        | "week"
        | "weeks"
        | "day"
        | "days"
        | "hour"
        | "hours"
        | "minute"
        | "minutes"
        | "second"
        | "seconds";

    /**
     * Value of the `unit` property in objects returned by
     * `Intl.RelativeTimeFormat.prototype.formatToParts()`. `formatToParts` and
     * `format` methods accept either singular or plural unit names as input,
     * but `formatToParts` only outputs singular (e.g. "day") not plural (e.g.
     * "days").
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/formatToParts#Using_formatToParts).
     */
    type RelativeTimeFormatUnitSingular =
        | "year"
        | "quarter"
        | "month"
        | "week"
        | "day"
        | "hour"
        | "minute"
        | "second";

    /**
     * The locale matching algorithm to use.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_negotiation).
     */
    type RelativeTimeFormatLocaleMatcher = "lookup" | "best fit";

    /**
     * The format of output message.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/RelativeTimeFormat#Parameters).
     */
    type RelativeTimeFormatNumeric = "always" | "auto";

    /**
     * The length of the internationalized message.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/RelativeTimeFormat#Parameters).
     */
    type RelativeTimeFormatStyle = "long" | "short" | "narrow";

    /**
     * The locale or locales to use
     *
     * See [MDN - Intl - locales argument](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#locales_argument).
     */
    type LocalesArgument = UnicodeBCP47LocaleIdentifier | Locale | readonly (UnicodeBCP47LocaleIdentifier | Locale)[] | undefined;

    /**
     * An object with some or all of properties of `options` parameter
     * of `Intl.RelativeTimeFormat` constructor.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/RelativeTimeFormat#Parameters).
     */
    interface RelativeTimeFormatOptions {
        /** The locale matching algorithm to use. For information about this option, see [Intl page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_negotiation). */
        localeMatcher?: RelativeTimeFormatLocaleMatcher;
        /** The format of output message. */
        numeric?: RelativeTimeFormatNumeric;
        /** The length of the internationalized message. */
        style?: RelativeTimeFormatStyle;
    }

    /**
     * An object with properties reflecting the locale
     * and formatting options computed during initialization
     * of the `Intl.RelativeTimeFormat` object
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/resolvedOptions#Description).
     */
    interface ResolvedRelativeTimeFormatOptions {
        locale: UnicodeBCP47LocaleIdentifier;
        style: RelativeTimeFormatStyle;
        numeric: RelativeTimeFormatNumeric;
        numberingSystem: string;
    }

    /**
     * An object representing the relative time format in parts
     * that can be used for custom locale-aware formatting.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/formatToParts#Using_formatToParts).
     */
    type RelativeTimeFormatPart =
        | {
            type: "literal";
            value: string;
        }
        | {
            type: Exclude<NumberFormatPartTypes, "literal">;
            value: string;
            unit: RelativeTimeFormatUnitSingular;
        };

    interface RelativeTimeFormat {
        /**
         * Formats a value and a unit according to the locale
         * and formatting options of the given
         * [`Intl.RelativeTimeFormat`](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/RelativeTimeFormat)
         * object.
         *
         * While this method automatically provides the correct plural forms,
         * the grammatical form is otherwise as neutral as possible.
         *
         * It is the caller's responsibility to handle cut-off logic
         * such as deciding between displaying "in 7 days" or "in 1 week".
         * This API does not support relative dates involving compound units.
         * e.g "in 5 days and 4 hours".
         *
         * @param value -  Numeric value to use in the internationalized relative time message
         *
         * @param unit - [Unit](https://tc39.es/ecma402/#sec-singularrelativetimeunit) to use in the relative time internationalized message.
         *
         * @throws `RangeError` if `unit` was given something other than `unit` possible values
         *
         * @returns {string} Internationalized relative time message as string
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/format).
         */
        format(value: number, unit: RelativeTimeFormatUnit): string;

        /**
         * Returns an array of objects representing the relative time format in parts that can be used for custom locale-aware formatting.
         *
         * @param value - Numeric value to use in the internationalized relative time message
         *
         * @param unit - [Unit](https://tc39.es/ecma402/#sec-singularrelativetimeunit) to use in the relative time internationalized message.
         *
         * @throws `RangeError` if `unit` was given something other than `unit` possible values
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/formatToParts).
         */
        formatToParts(value: number, unit: RelativeTimeFormatUnit): RelativeTimeFormatPart[];

        /**
         * Provides access to the locale and options computed during initialization of this `Intl.RelativeTimeFormat` object.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/resolvedOptions).
         */
        resolvedOptions(): ResolvedRelativeTimeFormatOptions;
    }

    /**
     * The [`Intl.RelativeTimeFormat`](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/RelativeTimeFormat)
     * object is a constructor for objects that enable language-sensitive relative time formatting.
     *
     * [Compatibility](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat#Browser_compatibility).
     */
    const RelativeTimeFormat: {
        /**
         * Creates [Intl.RelativeTimeFormat](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/RelativeTimeFormat) objects
         *
         * @param locales - A string with a [BCP 47 language tag](http://tools.ietf.org/html/rfc5646), or an array of such strings.
         *  For the general form and interpretation of the locales argument,
         *  see the [`Intl` page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_identification_and_negotiation).
         *
         * @param options - An [object](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/RelativeTimeFormat#Parameters)
         *  with some or all of options of `RelativeTimeFormatOptions`.
         *
         * @returns [Intl.RelativeTimeFormat](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/RelativeTimeFormat) object.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/RelativeTimeFormat).
         */
        new (
            locales?: LocalesArgument,
            options?: RelativeTimeFormatOptions,
        ): RelativeTimeFormat;

        /**
         * Returns an array containing those of the provided locales
         * that are supported in date and time formatting
         * without having to fall back to the runtime's default locale.
         *
         * @param locales - A string with a [BCP 47 language tag](http://tools.ietf.org/html/rfc5646), or an array of such strings.
         *  For the general form and interpretation of the locales argument,
         *  see the [`Intl` page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_identification_and_negotiation).
         *
         * @param options - An [object](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/RelativeTimeFormat#Parameters)
         *  with some or all of options of the formatting.
         *
         * @returns An array containing those of the provided locales
         *  that are supported in date and time formatting
         *  without having to fall back to the runtime's default locale.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat/supportedLocalesOf).
         */
        supportedLocalesOf(
            locales?: LocalesArgument,
            options?: RelativeTimeFormatOptions,
        ): UnicodeBCP47LocaleIdentifier[];
    };

    interface NumberFormatOptionsStyleRegistry {
        unit: never;
    }

    interface NumberFormatOptionsCurrencyDisplayRegistry {
        narrowSymbol: never;
    }

    interface NumberFormatOptionsSignDisplayRegistry {
        auto: never;
        never: never;
        always: never;
        exceptZero: never;
    }

    type NumberFormatOptionsSignDisplay = keyof NumberFormatOptionsSignDisplayRegistry;

    interface NumberFormatOptions {
        numberingSystem?: string | undefined;
        compactDisplay?: "short" | "long" | undefined;
        notation?: "standard" | "scientific" | "engineering" | "compact" | undefined;
        signDisplay?: NumberFormatOptionsSignDisplay | undefined;
        unit?: string | undefined;
        unitDisplay?: "short" | "long" | "narrow" | undefined;
        currencySign?: "standard" | "accounting" | undefined;
    }

    interface ResolvedNumberFormatOptions {
        compactDisplay?: "short" | "long";
        notation: "standard" | "scientific" | "engineering" | "compact";
        signDisplay: NumberFormatOptionsSignDisplay;
        unit?: string;
        unitDisplay?: "short" | "long" | "narrow";
        currencySign?: "standard" | "accounting";
    }

    interface NumberFormatPartTypeRegistry {
        compact: never;
        exponentInteger: never;
        exponentMinusSign: never;
        exponentSeparator: never;
        unit: never;
        unknown: never;
    }

    interface DateTimeFormatOptions {
        calendar?: string | undefined;
        dayPeriod?: "narrow" | "short" | "long" | undefined;
        numberingSystem?: string | undefined;

        dateStyle?: "full" | "long" | "medium" | "short" | undefined;
        timeStyle?: "full" | "long" | "medium" | "short" | undefined;
        hourCycle?: "h11" | "h12" | "h23" | "h24" | undefined;
    }

    type LocaleHourCycleKey = "h12" | "h23" | "h11" | "h24";
    type LocaleCollationCaseFirst = "upper" | "lower" | "false";

    interface LocaleOptions {
        /** A string containing the language, and the script and region if available. */
        baseName?: string;
        /** The part of the Locale that indicates the locale's calendar era. */
        calendar?: string;
        /** Flag that defines whether case is taken into account for the locale's collation rules. */
        caseFirst?: LocaleCollationCaseFirst;
        /** The collation type used for sorting */
        collation?: string;
        /** The time keeping format convention used by the locale. */
        hourCycle?: LocaleHourCycleKey;
        /** The primary language subtag associated with the locale. */
        language?: string;
        /** The numeral system used by the locale. */
        numberingSystem?: string;
        /** Flag that defines whether the locale has special collation handling for numeric characters. */
        numeric?: boolean;
        /** The region of the world (usually a country) associated with the locale. Possible values are region codes as defined by ISO 3166-1. */
        region?: string;
        /** The script used for writing the particular language used in the locale. Possible values are script codes as defined by ISO 15924. */
        script?: string;
    }

    interface Locale extends LocaleOptions {
        /** A string containing the language, and the script and region if available. */
        baseName: string;
        /** The primary language subtag associated with the locale. */
        language: string;
        /** Gets the most likely values for the language, script, and region of the locale based on existing values. */
        maximize(): Locale;
        /** Attempts to remove information about the locale that would be added by calling `Locale.maximize()`. */
        minimize(): Locale;
        /** Returns the locale's full locale identifier string. */
        toString(): UnicodeBCP47LocaleIdentifier;
    }

    /**
     * Constructor creates [Intl.Locale](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale)
     * objects
     *
     * @param tag - A string with a [BCP 47 language tag](http://tools.ietf.org/html/rfc5646).
     *  For the general form and interpretation of the locales argument,
     *  see the [`Intl` page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_identification_and_negotiation).
     *
     * @param options - An [object](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/Locale#Parameters) with some or all of options of the locale.
     *
     * @returns [Intl.Locale](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale) object.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale).
     */
    const Locale: {
        new (tag: UnicodeBCP47LocaleIdentifier | Locale, options?: LocaleOptions): Locale;
    };

    type DisplayNamesFallback =
        | "code"
        | "none";

    type DisplayNamesType =
        | "language"
        | "region"
        | "script"
        | "calendar"
        | "dateTimeField"
        | "currency";

    type DisplayNamesLanguageDisplay =
        | "dialect"
        | "standard";

    interface DisplayNamesOptions {
        localeMatcher?: RelativeTimeFormatLocaleMatcher;
        style?: RelativeTimeFormatStyle;
        type: DisplayNamesType;
        languageDisplay?: DisplayNamesLanguageDisplay;
        fallback?: DisplayNamesFallback;
    }

    interface ResolvedDisplayNamesOptions {
        locale: UnicodeBCP47LocaleIdentifier;
        style: RelativeTimeFormatStyle;
        type: DisplayNamesType;
        fallback: DisplayNamesFallback;
        languageDisplay?: DisplayNamesLanguageDisplay;
    }

    interface DisplayNames {
        /**
         * Receives a code and returns a string based on the locale and options provided when instantiating
         * [`Intl.DisplayNames()`](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames)
         *
         * @param code The `code` to provide depends on the `type` passed to display name during creation:
         *  - If the type is `"region"`, code should be either an [ISO-3166 two letters region code](https://www.iso.org/iso-3166-country-codes.html),
         *    or a [three digits UN M49 Geographic Regions](https://unstats.un.org/unsd/methodology/m49/).
         *  - If the type is `"script"`, code should be an [ISO-15924 four letters script code](https://unicode.org/iso15924/iso15924-codes.html).
         *  - If the type is `"language"`, code should be a `languageCode` ["-" `scriptCode`] ["-" `regionCode` ] *("-" `variant` )
         *    subsequence of the unicode_language_id grammar in [UTS 35's Unicode Language and Locale Identifiers grammar](https://unicode.org/reports/tr35/#Unicode_language_identifier).
         *    `languageCode` is either a two letters ISO 639-1 language code or a three letters ISO 639-2 language code.
         *  - If the type is `"currency"`, code should be a [3-letter ISO 4217 currency code](https://www.iso.org/iso-4217-currency-codes.html).
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames/of).
         */
        of(code: string): string | undefined;
        /**
         * Returns a new object with properties reflecting the locale and style formatting options computed during the construction of the current
         * [`Intl/DisplayNames`](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames) object.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames/resolvedOptions).
         */
        resolvedOptions(): ResolvedDisplayNamesOptions;
    }

    /**
     * The [`Intl.DisplayNames()`](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames)
     * object enables the consistent translation of language, region and script display names.
     *
     * [Compatibility](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames#browser_compatibility).
     */
    const DisplayNames: {
        prototype: DisplayNames;

        /**
         * @param locales A string with a BCP 47 language tag, or an array of such strings.
         *   For the general form and interpretation of the `locales` argument, see the [Intl](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#locale_identification_and_negotiation)
         *   page.
         *
         * @param options An object for setting up a display name.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames/DisplayNames).
         */
        new (locales: LocalesArgument, options: DisplayNamesOptions): DisplayNames;

        /**
         * Returns an array containing those of the provided locales that are supported in display names without having to fall back to the runtime's default locale.
         *
         * @param locales A string with a BCP 47 language tag, or an array of such strings.
         *   For the general form and interpretation of the `locales` argument, see the [Intl](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#locale_identification_and_negotiation)
         *   page.
         *
         * @param options An object with a locale matcher.
         *
         * @returns An array of strings representing a subset of the given locale tags that are supported in display names without having to fall back to the runtime's default locale.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames/supportedLocalesOf).
         */
        supportedLocalesOf(locales?: LocalesArgument, options?: { localeMatcher?: RelativeTimeFormatLocaleMatcher; }): UnicodeBCP47LocaleIdentifier[];
    };

    interface CollatorConstructor {
        new (locales?: LocalesArgument, options?: CollatorOptions): Collator;
        (locales?: LocalesArgument, options?: CollatorOptions): Collator;
        supportedLocalesOf(locales: LocalesArgument, options?: CollatorOptions): string[];
    }

    interface DateTimeFormatConstructor {
        new (locales?: LocalesArgument, options?: DateTimeFormatOptions): DateTimeFormat;
        (locales?: LocalesArgument, options?: DateTimeFormatOptions): DateTimeFormat;
        supportedLocalesOf(locales: LocalesArgument, options?: DateTimeFormatOptions): string[];
    }

    interface NumberFormatConstructor {
        new (locales?: LocalesArgument, options?: NumberFormatOptions): NumberFormat;
        (locales?: LocalesArgument, options?: NumberFormatOptions): NumberFormat;
        supportedLocalesOf(locales: LocalesArgument, options?: NumberFormatOptions): string[];
    }

    interface PluralRulesConstructor {
        new (locales?: LocalesArgument, options?: PluralRulesOptions): PluralRules;
        (locales?: LocalesArgument, options?: PluralRulesOptions): PluralRules;

        supportedLocalesOf(locales: LocalesArgument, options?: { localeMatcher?: "lookup" | "best fit"; }): string[];
    }
}

//========== lib.es2020.bigint.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2020.intl" />

interface BigIntToLocaleStringOptions {
    /**
     * The locale matching algorithm to use.The default is "best fit". For information about this option, see the {@link https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_negotiation Intl page}.
     */
    localeMatcher?: string;
    /**
     * The formatting style to use , the default is "decimal".
     */
    style?: string;

    numberingSystem?: string;
    /**
     * The unit to use in unit formatting, Possible values are core unit identifiers, defined in UTS #35, Part 2, Section 6. A subset of units from the full list was selected for use in ECMAScript. Pairs of simple units can be concatenated with "-per-" to make a compound unit. There is no default value; if the style is "unit", the unit property must be provided.
     */
    unit?: string;

    /**
     * The unit formatting style to use in unit formatting, the defaults is "short".
     */
    unitDisplay?: string;

    /**
     * The currency to use in currency formatting. Possible values are the ISO 4217 currency codes, such as "USD" for the US dollar, "EUR" for the euro, or "CNY" for the Chinese RMB — see the Current currency & funds code list. There is no default value; if the style is "currency", the currency property must be provided. It is only used when [[Style]] has the value "currency".
     */
    currency?: string;

    /**
     * How to display the currency in currency formatting. It is only used when [[Style]] has the value "currency". The default is "symbol".
     *
     * "symbol" to use a localized currency symbol such as €,
     *
     * "code" to use the ISO currency code,
     *
     * "name" to use a localized currency name such as "dollar"
     */
    currencyDisplay?: string;

    /**
     * Whether to use grouping separators, such as thousands separators or thousand/lakh/crore separators. The default is true.
     */
    useGrouping?: boolean;

    /**
     * The minimum number of integer digits to use. Possible values are from 1 to 21; the default is 1.
     */
    minimumIntegerDigits?: 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21;

    /**
     * The minimum number of fraction digits to use. Possible values are from 0 to 20; the default for plain number and percent formatting is 0; the default for currency formatting is the number of minor unit digits provided by the {@link http://www.currency-iso.org/en/home/tables/table-a1.html ISO 4217 currency codes list} (2 if the list doesn't provide that information).
     */
    minimumFractionDigits?: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20;

    /**
     * The maximum number of fraction digits to use. Possible values are from 0 to 20; the default for plain number formatting is the larger of minimumFractionDigits and 3; the default for currency formatting is the larger of minimumFractionDigits and the number of minor unit digits provided by the {@link http://www.currency-iso.org/en/home/tables/table-a1.html ISO 4217 currency codes list} (2 if the list doesn't provide that information); the default for percent formatting is the larger of minimumFractionDigits and 0.
     */
    maximumFractionDigits?: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20;

    /**
     * The minimum number of significant digits to use. Possible values are from 1 to 21; the default is 1.
     */
    minimumSignificantDigits?: 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21;

    /**
     * The maximum number of significant digits to use. Possible values are from 1 to 21; the default is 21.
     */
    maximumSignificantDigits?: 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21;

    /**
     * The formatting that should be displayed for the number, the defaults is "standard"
     *
     *     "standard" plain number formatting
     *
     *     "scientific" return the order-of-magnitude for formatted number.
     *
     *     "engineering" return the exponent of ten when divisible by three
     *
     *     "compact" string representing exponent, defaults is using the "short" form
     */
    notation?: string;

    /**
     * used only when notation is "compact"
     */
    compactDisplay?: string;
}

interface BigInt {
    /**
     * Returns a string representation of an object.
     * @param radix Specifies a radix for converting numeric values to strings.
     */
    toString(radix?: number): string;

    /** Returns a string representation appropriate to the host environment's current locale. */
    toLocaleString(locales?: Intl.LocalesArgument, options?: BigIntToLocaleStringOptions): string;

    /** Returns the primitive value of the specified object. */
    valueOf(): bigint;

    readonly [Symbol.toStringTag]: "BigInt";
}

interface BigIntConstructor {
    (value: bigint | boolean | number | string): bigint;
    readonly prototype: BigInt;

    /**
     * Interprets the low bits of a BigInt as a 2's-complement signed integer.
     * All higher bits are discarded.
     * @param bits The number of low bits to use
     * @param int The BigInt whose bits to extract
     */
    asIntN(bits: number, int: bigint): bigint;
    /**
     * Interprets the low bits of a BigInt as an unsigned integer.
     * All higher bits are discarded.
     * @param bits The number of low bits to use
     * @param int The BigInt whose bits to extract
     */
    asUintN(bits: number, int: bigint): bigint;
}

declare var BigInt: BigIntConstructor;

/**
 * A typed array of 64-bit signed integer values. The contents are initialized to 0. If the
 * requested number of bytes could not be allocated, an exception is raised.
 */
interface BigInt64Array<TArrayBuffer extends ArrayBufferLike = ArrayBufferLike> {
    /** The size in bytes of each element in the array. */
    readonly BYTES_PER_ELEMENT: number;

    /** The ArrayBuffer instance referenced by the array. */
    readonly buffer: TArrayBuffer;

    /** The length in bytes of the array. */
    readonly byteLength: number;

    /** The offset in bytes of the array. */
    readonly byteOffset: number;

    /**
     * Returns the this object after copying a section of the array identified by start and end
     * to the same array starting at position target
     * @param target If target is negative, it is treated as length+target where length is the
     * length of the array.
     * @param start If start is negative, it is treated as length+start. If end is negative, it
     * is treated as length+end.
     * @param end If not specified, length of the this object is used as its default value.
     */
    copyWithin(target: number, start: number, end?: number): this;

    /** Yields index, value pairs for every entry in the array. */
    entries(): ArrayIterator<[number, bigint]>;

    /**
     * Determines whether all the members of an array satisfy the specified test.
     * @param predicate A function that accepts up to three arguments. The every method calls
     * the predicate function for each element in the array until the predicate returns false,
     * or until the end of the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    every(predicate: (value: bigint, index: number, array: BigInt64Array<TArrayBuffer>) => boolean, thisArg?: any): boolean;

    /**
     * Changes all array elements from `start` to `end` index to a static `value` and returns the modified array
     * @param value value to fill array section with
     * @param start index to start filling the array at. If start is negative, it is treated as
     * length+start where length is the length of the array.
     * @param end index to stop filling the array at. If end is negative, it is treated as
     * length+end.
     */
    fill(value: bigint, start?: number, end?: number): this;

    /**
     * Returns the elements of an array that meet the condition specified in a callback function.
     * @param predicate A function that accepts up to three arguments. The filter method calls
     * the predicate function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    filter(predicate: (value: bigint, index: number, array: BigInt64Array<TArrayBuffer>) => any, thisArg?: any): BigInt64Array<ArrayBuffer>;

    /**
     * Returns the value of the first element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate find calls predicate once for each element of the array, in ascending
     * order, until it finds one where predicate returns true. If such an element is found, find
     * immediately returns that element value. Otherwise, find returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    find(predicate: (value: bigint, index: number, array: BigInt64Array<TArrayBuffer>) => boolean, thisArg?: any): bigint | undefined;

    /**
     * Returns the index of the first element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate find calls predicate once for each element of the array, in ascending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findIndex immediately returns that element index. Otherwise, findIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findIndex(predicate: (value: bigint, index: number, array: BigInt64Array<TArrayBuffer>) => boolean, thisArg?: any): number;

    /**
     * Performs the specified action for each element in an array.
     * @param callbackfn A function that accepts up to three arguments. forEach calls the
     * callbackfn function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the callbackfn function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    forEach(callbackfn: (value: bigint, index: number, array: BigInt64Array<TArrayBuffer>) => void, thisArg?: any): void;

    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: bigint, fromIndex?: number): boolean;

    /**
     * Returns the index of the first occurrence of a value in an array, or -1 if it is not present.
     * @param searchElement The value to locate in the array.
     * @param fromIndex The array index at which to begin the search. If fromIndex is omitted, the
     * search starts at index 0.
     */
    indexOf(searchElement: bigint, fromIndex?: number): number;

    /**
     * Adds all the elements of an array separated by the specified separator string.
     * @param separator A string used to separate one element of an array from the next in the
     * resulting String. If omitted, the array elements are separated with a comma.
     */
    join(separator?: string): string;

    /** Yields each index in the array. */
    keys(): ArrayIterator<number>;

    /**
     * Returns the index of the last occurrence of a value in an array, or -1 if it is not present.
     * @param searchElement The value to locate in the array.
     * @param fromIndex The array index at which to begin the search. If fromIndex is omitted, the
     * search starts at index 0.
     */
    lastIndexOf(searchElement: bigint, fromIndex?: number): number;

    /** The length of the array. */
    readonly length: number;

    /**
     * Calls a defined callback function on each element of an array, and returns an array that
     * contains the results.
     * @param callbackfn A function that accepts up to three arguments. The map method calls the
     * callbackfn function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the callbackfn function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    map(callbackfn: (value: bigint, index: number, array: BigInt64Array<TArrayBuffer>) => bigint, thisArg?: any): BigInt64Array<ArrayBuffer>;

    /**
     * Calls the specified callback function for all the elements in an array. The return value of
     * the callback function is the accumulated result, and is provided as an argument in the next
     * call to the callback function.
     * @param callbackfn A function that accepts up to four arguments. The reduce method calls the
     * callbackfn function one time for each element in the array.
     * @param initialValue If initialValue is specified, it is used as the initial value to start
     * the accumulation. The first call to the callbackfn function provides this value as an argument
     * instead of an array value.
     */
    reduce(callbackfn: (previousValue: bigint, currentValue: bigint, currentIndex: number, array: BigInt64Array<TArrayBuffer>) => bigint): bigint;

    /**
     * Calls the specified callback function for all the elements in an array. The return value of
     * the callback function is the accumulated result, and is provided as an argument in the next
     * call to the callback function.
     * @param callbackfn A function that accepts up to four arguments. The reduce method calls the
     * callbackfn function one time for each element in the array.
     * @param initialValue If initialValue is specified, it is used as the initial value to start
     * the accumulation. The first call to the callbackfn function provides this value as an argument
     * instead of an array value.
     */
    reduce<U>(callbackfn: (previousValue: U, currentValue: bigint, currentIndex: number, array: BigInt64Array<TArrayBuffer>) => U, initialValue: U): U;

    /**
     * Calls the specified callback function for all the elements in an array, in descending order.
     * The return value of the callback function is the accumulated result, and is provided as an
     * argument in the next call to the callback function.
     * @param callbackfn A function that accepts up to four arguments. The reduceRight method calls
     * the callbackfn function one time for each element in the array.
     * @param initialValue If initialValue is specified, it is used as the initial value to start
     * the accumulation. The first call to the callbackfn function provides this value as an
     * argument instead of an array value.
     */
    reduceRight(callbackfn: (previousValue: bigint, currentValue: bigint, currentIndex: number, array: BigInt64Array<TArrayBuffer>) => bigint): bigint;

    /**
     * Calls the specified callback function for all the elements in an array, in descending order.
     * The return value of the callback function is the accumulated result, and is provided as an
     * argument in the next call to the callback function.
     * @param callbackfn A function that accepts up to four arguments. The reduceRight method calls
     * the callbackfn function one time for each element in the array.
     * @param initialValue If initialValue is specified, it is used as the initial value to start
     * the accumulation. The first call to the callbackfn function provides this value as an argument
     * instead of an array value.
     */
    reduceRight<U>(callbackfn: (previousValue: U, currentValue: bigint, currentIndex: number, array: BigInt64Array<TArrayBuffer>) => U, initialValue: U): U;

    /** Reverses the elements in the array. */
    reverse(): this;

    /**
     * Sets a value or an array of values.
     * @param array A typed or untyped array of values to set.
     * @param offset The index in the current array at which the values are to be written.
     */
    set(array: ArrayLike<bigint>, offset?: number): void;

    /**
     * Returns a section of an array.
     * @param start The beginning of the specified portion of the array.
     * @param end The end of the specified portion of the array.
     */
    slice(start?: number, end?: number): BigInt64Array<ArrayBuffer>;

    /**
     * Determines whether the specified callback function returns true for any element of an array.
     * @param predicate A function that accepts up to three arguments. The some method calls the
     * predicate function for each element in the array until the predicate returns true, or until
     * the end of the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    some(predicate: (value: bigint, index: number, array: BigInt64Array<TArrayBuffer>) => boolean, thisArg?: any): boolean;

    /**
     * Sorts the array.
     * @param compareFn The function used to determine the order of the elements. If omitted, the elements are sorted in ascending order.
     */
    sort(compareFn?: (a: bigint, b: bigint) => number | bigint): this;

    /**
     * Gets a new BigInt64Array view of the ArrayBuffer store for this array, referencing the elements
     * at begin, inclusive, up to end, exclusive.
     * @param begin The index of the beginning of the array.
     * @param end The index of the end of the array.
     */
    subarray(begin?: number, end?: number): BigInt64Array<TArrayBuffer>;

    /** Converts the array to a string by using the current locale. */
    toLocaleString(locales?: string | string[], options?: Intl.NumberFormatOptions): string;

    /** Returns a string representation of the array. */
    toString(): string;

    /** Returns the primitive value of the specified object. */
    valueOf(): BigInt64Array<TArrayBuffer>;

    /** Yields each value in the array. */
    values(): ArrayIterator<bigint>;

    [Symbol.iterator](): ArrayIterator<bigint>;

    readonly [Symbol.toStringTag]: "BigInt64Array";

    [index: number]: bigint;
}
interface BigInt64ArrayConstructor {
    readonly prototype: BigInt64Array<ArrayBufferLike>;
    new (length?: number): BigInt64Array<ArrayBuffer>;
    new (array: ArrayLike<bigint> | Iterable<bigint>): BigInt64Array<ArrayBuffer>;
    new <TArrayBuffer extends ArrayBufferLike = ArrayBuffer>(buffer: TArrayBuffer, byteOffset?: number, length?: number): BigInt64Array<TArrayBuffer>;
    new (buffer: ArrayBuffer, byteOffset?: number, length?: number): BigInt64Array<ArrayBuffer>;
    new (array: ArrayLike<bigint> | ArrayBuffer): BigInt64Array<ArrayBuffer>;

    /** The size in bytes of each element in the array. */
    readonly BYTES_PER_ELEMENT: number;

    /**
     * Returns a new array from a set of elements.
     * @param items A set of elements to include in the new array object.
     */
    of(...items: bigint[]): BigInt64Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param arrayLike An array-like object to convert to an array.
     */
    from(arrayLike: ArrayLike<bigint>): BigInt64Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param arrayLike An array-like object to convert to an array.
     * @param mapfn A mapping function to call on every element of the array.
     * @param thisArg Value of 'this' used to invoke the mapfn.
     */
    from<U>(arrayLike: ArrayLike<U>, mapfn: (v: U, k: number) => bigint, thisArg?: any): BigInt64Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param elements An iterable object to convert to an array.
     */
    from(elements: Iterable<bigint>): BigInt64Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param elements An iterable object to convert to an array.
     * @param mapfn A mapping function to call on every element of the array.
     * @param thisArg Value of 'this' used to invoke the mapfn.
     */
    from<T>(elements: Iterable<T>, mapfn?: (v: T, k: number) => bigint, thisArg?: any): BigInt64Array<ArrayBuffer>;
}
declare var BigInt64Array: BigInt64ArrayConstructor;

/**
 * A typed array of 64-bit unsigned integer values. The contents are initialized to 0. If the
 * requested number of bytes could not be allocated, an exception is raised.
 */
interface BigUint64Array<TArrayBuffer extends ArrayBufferLike = ArrayBufferLike> {
    /** The size in bytes of each element in the array. */
    readonly BYTES_PER_ELEMENT: number;

    /** The ArrayBuffer instance referenced by the array. */
    readonly buffer: TArrayBuffer;

    /** The length in bytes of the array. */
    readonly byteLength: number;

    /** The offset in bytes of the array. */
    readonly byteOffset: number;

    /**
     * Returns the this object after copying a section of the array identified by start and end
     * to the same array starting at position target
     * @param target If target is negative, it is treated as length+target where length is the
     * length of the array.
     * @param start If start is negative, it is treated as length+start. If end is negative, it
     * is treated as length+end.
     * @param end If not specified, length of the this object is used as its default value.
     */
    copyWithin(target: number, start: number, end?: number): this;

    /** Yields index, value pairs for every entry in the array. */
    entries(): ArrayIterator<[number, bigint]>;

    /**
     * Determines whether all the members of an array satisfy the specified test.
     * @param predicate A function that accepts up to three arguments. The every method calls
     * the predicate function for each element in the array until the predicate returns false,
     * or until the end of the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    every(predicate: (value: bigint, index: number, array: BigUint64Array<TArrayBuffer>) => boolean, thisArg?: any): boolean;

    /**
     * Changes all array elements from `start` to `end` index to a static `value` and returns the modified array
     * @param value value to fill array section with
     * @param start index to start filling the array at. If start is negative, it is treated as
     * length+start where length is the length of the array.
     * @param end index to stop filling the array at. If end is negative, it is treated as
     * length+end.
     */
    fill(value: bigint, start?: number, end?: number): this;

    /**
     * Returns the elements of an array that meet the condition specified in a callback function.
     * @param predicate A function that accepts up to three arguments. The filter method calls
     * the predicate function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    filter(predicate: (value: bigint, index: number, array: BigUint64Array<TArrayBuffer>) => any, thisArg?: any): BigUint64Array<ArrayBuffer>;

    /**
     * Returns the value of the first element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate find calls predicate once for each element of the array, in ascending
     * order, until it finds one where predicate returns true. If such an element is found, find
     * immediately returns that element value. Otherwise, find returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    find(predicate: (value: bigint, index: number, array: BigUint64Array<TArrayBuffer>) => boolean, thisArg?: any): bigint | undefined;

    /**
     * Returns the index of the first element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate find calls predicate once for each element of the array, in ascending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findIndex immediately returns that element index. Otherwise, findIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findIndex(predicate: (value: bigint, index: number, array: BigUint64Array<TArrayBuffer>) => boolean, thisArg?: any): number;

    /**
     * Performs the specified action for each element in an array.
     * @param callbackfn A function that accepts up to three arguments. forEach calls the
     * callbackfn function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the callbackfn function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    forEach(callbackfn: (value: bigint, index: number, array: BigUint64Array<TArrayBuffer>) => void, thisArg?: any): void;

    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: bigint, fromIndex?: number): boolean;

    /**
     * Returns the index of the first occurrence of a value in an array, or -1 if it is not present.
     * @param searchElement The value to locate in the array.
     * @param fromIndex The array index at which to begin the search. If fromIndex is omitted, the
     * search starts at index 0.
     */
    indexOf(searchElement: bigint, fromIndex?: number): number;

    /**
     * Adds all the elements of an array separated by the specified separator string.
     * @param separator A string used to separate one element of an array from the next in the
     * resulting String. If omitted, the array elements are separated with a comma.
     */
    join(separator?: string): string;

    /** Yields each index in the array. */
    keys(): ArrayIterator<number>;

    /**
     * Returns the index of the last occurrence of a value in an array, or -1 if it is not present.
     * @param searchElement The value to locate in the array.
     * @param fromIndex The array index at which to begin the search. If fromIndex is omitted, the
     * search starts at index 0.
     */
    lastIndexOf(searchElement: bigint, fromIndex?: number): number;

    /** The length of the array. */
    readonly length: number;

    /**
     * Calls a defined callback function on each element of an array, and returns an array that
     * contains the results.
     * @param callbackfn A function that accepts up to three arguments. The map method calls the
     * callbackfn function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the callbackfn function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    map(callbackfn: (value: bigint, index: number, array: BigUint64Array<TArrayBuffer>) => bigint, thisArg?: any): BigUint64Array<ArrayBuffer>;

    /**
     * Calls the specified callback function for all the elements in an array. The return value of
     * the callback function is the accumulated result, and is provided as an argument in the next
     * call to the callback function.
     * @param callbackfn A function that accepts up to four arguments. The reduce method calls the
     * callbackfn function one time for each element in the array.
     * @param initialValue If initialValue is specified, it is used as the initial value to start
     * the accumulation. The first call to the callbackfn function provides this value as an argument
     * instead of an array value.
     */
    reduce(callbackfn: (previousValue: bigint, currentValue: bigint, currentIndex: number, array: BigUint64Array<TArrayBuffer>) => bigint): bigint;

    /**
     * Calls the specified callback function for all the elements in an array. The return value of
     * the callback function is the accumulated result, and is provided as an argument in the next
     * call to the callback function.
     * @param callbackfn A function that accepts up to four arguments. The reduce method calls the
     * callbackfn function one time for each element in the array.
     * @param initialValue If initialValue is specified, it is used as the initial value to start
     * the accumulation. The first call to the callbackfn function provides this value as an argument
     * instead of an array value.
     */
    reduce<U>(callbackfn: (previousValue: U, currentValue: bigint, currentIndex: number, array: BigUint64Array<TArrayBuffer>) => U, initialValue: U): U;

    /**
     * Calls the specified callback function for all the elements in an array, in descending order.
     * The return value of the callback function is the accumulated result, and is provided as an
     * argument in the next call to the callback function.
     * @param callbackfn A function that accepts up to four arguments. The reduceRight method calls
     * the callbackfn function one time for each element in the array.
     * @param initialValue If initialValue is specified, it is used as the initial value to start
     * the accumulation. The first call to the callbackfn function provides this value as an
     * argument instead of an array value.
     */
    reduceRight(callbackfn: (previousValue: bigint, currentValue: bigint, currentIndex: number, array: BigUint64Array<TArrayBuffer>) => bigint): bigint;

    /**
     * Calls the specified callback function for all the elements in an array, in descending order.
     * The return value of the callback function is the accumulated result, and is provided as an
     * argument in the next call to the callback function.
     * @param callbackfn A function that accepts up to four arguments. The reduceRight method calls
     * the callbackfn function one time for each element in the array.
     * @param initialValue If initialValue is specified, it is used as the initial value to start
     * the accumulation. The first call to the callbackfn function provides this value as an argument
     * instead of an array value.
     */
    reduceRight<U>(callbackfn: (previousValue: U, currentValue: bigint, currentIndex: number, array: BigUint64Array<TArrayBuffer>) => U, initialValue: U): U;

    /** Reverses the elements in the array. */
    reverse(): this;

    /**
     * Sets a value or an array of values.
     * @param array A typed or untyped array of values to set.
     * @param offset The index in the current array at which the values are to be written.
     */
    set(array: ArrayLike<bigint>, offset?: number): void;

    /**
     * Returns a section of an array.
     * @param start The beginning of the specified portion of the array.
     * @param end The end of the specified portion of the array.
     */
    slice(start?: number, end?: number): BigUint64Array<ArrayBuffer>;

    /**
     * Determines whether the specified callback function returns true for any element of an array.
     * @param predicate A function that accepts up to three arguments. The some method calls the
     * predicate function for each element in the array until the predicate returns true, or until
     * the end of the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    some(predicate: (value: bigint, index: number, array: BigUint64Array<TArrayBuffer>) => boolean, thisArg?: any): boolean;

    /**
     * Sorts the array.
     * @param compareFn The function used to determine the order of the elements. If omitted, the elements are sorted in ascending order.
     */
    sort(compareFn?: (a: bigint, b: bigint) => number | bigint): this;

    /**
     * Gets a new BigUint64Array view of the ArrayBuffer store for this array, referencing the elements
     * at begin, inclusive, up to end, exclusive.
     * @param begin The index of the beginning of the array.
     * @param end The index of the end of the array.
     */
    subarray(begin?: number, end?: number): BigUint64Array<TArrayBuffer>;

    /** Converts the array to a string by using the current locale. */
    toLocaleString(locales?: string | string[], options?: Intl.NumberFormatOptions): string;

    /** Returns a string representation of the array. */
    toString(): string;

    /** Returns the primitive value of the specified object. */
    valueOf(): BigUint64Array<TArrayBuffer>;

    /** Yields each value in the array. */
    values(): ArrayIterator<bigint>;

    [Symbol.iterator](): ArrayIterator<bigint>;

    readonly [Symbol.toStringTag]: "BigUint64Array";

    [index: number]: bigint;
}
interface BigUint64ArrayConstructor {
    readonly prototype: BigUint64Array<ArrayBufferLike>;
    new (length?: number): BigUint64Array<ArrayBuffer>;
    new (array: ArrayLike<bigint> | Iterable<bigint>): BigUint64Array<ArrayBuffer>;
    new <TArrayBuffer extends ArrayBufferLike = ArrayBuffer>(buffer: TArrayBuffer, byteOffset?: number, length?: number): BigUint64Array<TArrayBuffer>;
    new (buffer: ArrayBuffer, byteOffset?: number, length?: number): BigUint64Array<ArrayBuffer>;
    new (array: ArrayLike<bigint> | ArrayBuffer): BigUint64Array<ArrayBuffer>;

    /** The size in bytes of each element in the array. */
    readonly BYTES_PER_ELEMENT: number;

    /**
     * Returns a new array from a set of elements.
     * @param items A set of elements to include in the new array object.
     */
    of(...items: bigint[]): BigUint64Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param arrayLike An array-like object to convert to an array.
     */
    from(arrayLike: ArrayLike<bigint>): BigUint64Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param arrayLike An array-like object to convert to an array.
     * @param mapfn A mapping function to call on every element of the array.
     * @param thisArg Value of 'this' used to invoke the mapfn.
     */
    from<U>(arrayLike: ArrayLike<U>, mapfn: (v: U, k: number) => bigint, thisArg?: any): BigUint64Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param elements An iterable object to convert to an array.
     */
    from(elements: Iterable<bigint>): BigUint64Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param elements An iterable object to convert to an array.
     * @param mapfn A mapping function to call on every element of the array.
     * @param thisArg Value of 'this' used to invoke the mapfn.
     */
    from<T>(elements: Iterable<T>, mapfn?: (v: T, k: number) => bigint, thisArg?: any): BigUint64Array<ArrayBuffer>;
}
declare var BigUint64Array: BigUint64ArrayConstructor;

interface DataView<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Gets the BigInt64 value at the specified byte offset from the start of the view. There is
     * no alignment constraint; multi-byte values may be fetched from any offset.
     * @param byteOffset The place in the buffer at which the value should be retrieved.
     * @param littleEndian If false or undefined, a big-endian value should be read.
     */
    getBigInt64(byteOffset: number, littleEndian?: boolean): bigint;

    /**
     * Gets the BigUint64 value at the specified byte offset from the start of the view. There is
     * no alignment constraint; multi-byte values may be fetched from any offset.
     * @param byteOffset The place in the buffer at which the value should be retrieved.
     * @param littleEndian If false or undefined, a big-endian value should be read.
     */
    getBigUint64(byteOffset: number, littleEndian?: boolean): bigint;

    /**
     * Stores a BigInt64 value at the specified byte offset from the start of the view.
     * @param byteOffset The place in the buffer at which the value should be set.
     * @param value The value to set.
     * @param littleEndian If false or undefined, a big-endian value should be written.
     */
    setBigInt64(byteOffset: number, value: bigint, littleEndian?: boolean): void;

    /**
     * Stores a BigUint64 value at the specified byte offset from the start of the view.
     * @param byteOffset The place in the buffer at which the value should be set.
     * @param value The value to set.
     * @param littleEndian If false or undefined, a big-endian value should be written.
     */
    setBigUint64(byteOffset: number, value: bigint, littleEndian?: boolean): void;
}

declare namespace Intl {
    interface NumberFormat {
        format(value: number | bigint): string;
    }
}

//========== lib.es2020.date.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2020.intl" />

interface Date {
    /**
     * Converts a date and time to a string by using the current or specified locale.
     * @param locales A locale string, array of locale strings, Intl.Locale object, or array of Intl.Locale objects that contain one or more language or locale tags. If you include more than one locale string, list them in descending order of priority so that the first entry is the preferred locale. If you omit this parameter, the default locale of the JavaScript runtime is used.
     * @param options An object that contains one or more properties that specify comparison options.
     */
    toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;

    /**
     * Converts a date to a string by using the current or specified locale.
     * @param locales A locale string, array of locale strings, Intl.Locale object, or array of Intl.Locale objects that contain one or more language or locale tags. If you include more than one locale string, list them in descending order of priority so that the first entry is the preferred locale. If you omit this parameter, the default locale of the JavaScript runtime is used.
     * @param options An object that contains one or more properties that specify comparison options.
     */
    toLocaleDateString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;

    /**
     * Converts a time to a string by using the current or specified locale.
     * @param locales A locale string, array of locale strings, Intl.Locale object, or array of Intl.Locale objects that contain one or more language or locale tags. If you include more than one locale string, list them in descending order of priority so that the first entry is the preferred locale. If you omit this parameter, the default locale of the JavaScript runtime is used.
     * @param options An object that contains one or more properties that specify comparison options.
     */
    toLocaleTimeString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;
}

//========== lib.es2020.number.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2020.intl" />

interface Number {
    /**
     * Converts a number to a string by using the current or specified locale.
     * @param locales A locale string, array of locale strings, Intl.Locale object, or array of Intl.Locale objects that contain one or more language or locale tags. If you include more than one locale string, list them in descending order of priority so that the first entry is the preferred locale. If you omit this parameter, the default locale of the JavaScript runtime is used.
     * @param options An object that contains one or more properties that specify comparison options.
     */
    toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.NumberFormatOptions): string;
}

//========== lib.es2020.promise.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface PromiseFulfilledResult<T> {
    status: "fulfilled";
    value: T;
}

interface PromiseRejectedResult {
    status: "rejected";
    reason: any;
}

type PromiseSettledResult<T> = PromiseFulfilledResult<T> | PromiseRejectedResult;

interface PromiseConstructor {
    /**
     * Creates a Promise that is resolved with an array of results when all
     * of the provided Promises resolve or reject.
     * @param values An array of Promises.
     * @returns A new Promise.
     */
    allSettled<T extends readonly unknown[] | []>(values: T): Promise<{ -readonly [P in keyof T]: PromiseSettledResult<Awaited<T[P]>>; }>;

    /**
     * Creates a Promise that is resolved with an array of results when all
     * of the provided Promises resolve or reject.
     * @param values An array of Promises.
     * @returns A new Promise.
     */
    allSettled<T>(values: Iterable<T | PromiseLike<T>>): Promise<PromiseSettledResult<Awaited<T>>[]>;
}

//========== lib.es2020.sharedmemory.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2020.bigint" />

interface Atomics {
    /**
     * Adds a value to the value at the given position in the array, returning the original value.
     * Until this atomic operation completes, any other read or write operation against the array
     * will block.
     */
    add(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number, value: bigint): bigint;

    /**
     * Stores the bitwise AND of a value with the value at the given position in the array,
     * returning the original value. Until this atomic operation completes, any other read or
     * write operation against the array will block.
     */
    and(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number, value: bigint): bigint;

    /**
     * Replaces the value at the given position in the array if the original value equals the given
     * expected value, returning the original value. Until this atomic operation completes, any
     * other read or write operation against the array will block.
     */
    compareExchange(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number, expectedValue: bigint, replacementValue: bigint): bigint;

    /**
     * Replaces the value at the given position in the array, returning the original value. Until
     * this atomic operation completes, any other read or write operation against the array will
     * block.
     */
    exchange(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number, value: bigint): bigint;

    /**
     * Returns the value at the given position in the array. Until this atomic operation completes,
     * any other read or write operation against the array will block.
     */
    load(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number): bigint;

    /**
     * Stores the bitwise OR of a value with the value at the given position in the array,
     * returning the original value. Until this atomic operation completes, any other read or write
     * operation against the array will block.
     */
    or(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number, value: bigint): bigint;

    /**
     * Stores a value at the given position in the array, returning the new value. Until this
     * atomic operation completes, any other read or write operation against the array will block.
     */
    store(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number, value: bigint): bigint;

    /**
     * Subtracts a value from the value at the given position in the array, returning the original
     * value. Until this atomic operation completes, any other read or write operation against the
     * array will block.
     */
    sub(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number, value: bigint): bigint;

    /**
     * If the value at the given position in the array is equal to the provided value, the current
     * agent is put to sleep causing execution to suspend until the timeout expires (returning
     * `"timed-out"`) or until the agent is awoken (returning `"ok"`); otherwise, returns
     * `"not-equal"`.
     */
    wait(typedArray: BigInt64Array<ArrayBufferLike>, index: number, value: bigint, timeout?: number): "ok" | "not-equal" | "timed-out";

    /**
     * Wakes up sleeping agents that are waiting on the given index of the array, returning the
     * number of agents that were awoken.
     * @param typedArray A shared BigInt64Array.
     * @param index The position in the typedArray to wake up on.
     * @param count The number of sleeping agents to notify. Defaults to +Infinity.
     */
    notify(typedArray: BigInt64Array<ArrayBufferLike>, index: number, count?: number): number;

    /**
     * Stores the bitwise XOR of a value with the value at the given position in the array,
     * returning the original value. Until this atomic operation completes, any other read or write
     * operation against the array will block.
     */
    xor(typedArray: BigInt64Array<ArrayBufferLike> | BigUint64Array<ArrayBufferLike>, index: number, value: bigint): bigint;
}

//========== lib.es2020.symbol.wellknown.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2015.iterable" />
/// <reference lib="es2015.symbol" />

interface SymbolConstructor {
    /**
     * A regular expression method that matches the regular expression against a string. Called
     * by the String.prototype.matchAll method.
     */
    readonly matchAll: unique symbol;
}

interface RegExpStringIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): RegExpStringIterator<T>;
}

interface RegExp {
    /**
     * Matches a string with this regular expression, and returns an iterable of matches
     * containing the results of that search.
     * @param string A string to search within.
     */
    [Symbol.matchAll](str: string): RegExpStringIterator<RegExpExecArray>;
}

//========== lib.es2020.string.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2015.iterable" />
/// <reference lib="es2020.intl" />
/// <reference lib="es2020.symbol.wellknown" />

interface String {
    /**
     * Matches a string with a regular expression, and returns an iterable of matches
     * containing the results of that search.
     * @param regexp A regular expression
     */
    matchAll(regexp: RegExp): RegExpStringIterator<RegExpExecArray>;

    /** Converts all alphabetic characters to lowercase, taking into account the host environment's current locale. */
    toLocaleLowerCase(locales?: Intl.LocalesArgument): string;

    /** Returns a string where all alphabetic characters have been converted to uppercase, taking into account the host environment's current locale. */
    toLocaleUpperCase(locales?: Intl.LocalesArgument): string;

    /**
     * Determines whether two strings are equivalent in the current or specified locale.
     * @param that String to compare to target string
     * @param locales A locale string or array of locale strings that contain one or more language or locale tags. If you include more than one locale string, list them in descending order of priority so that the first entry is the preferred locale. If you omit this parameter, the default locale of the JavaScript runtime is used. This parameter must conform to BCP 47 standards; see the Intl.Collator object for details.
     * @param options An object that contains one or more properties that specify comparison options. see the Intl.Collator object for details.
     */
    localeCompare(that: string, locales?: Intl.LocalesArgument, options?: Intl.CollatorOptions): number;
}

//========== lib.es2020.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2019" />
/// <reference lib="es2020.bigint" />
/// <reference lib="es2020.date" />
/// <reference lib="es2020.number" />
/// <reference lib="es2020.promise" />
/// <reference lib="es2020.sharedmemory" />
/// <reference lib="es2020.string" />
/// <reference lib="es2020.symbol.wellknown" />
/// <reference lib="es2020.intl" />

//========== lib.es2021.promise.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface AggregateError extends Error {
    errors: any[];
}

interface AggregateErrorConstructor {
    new (errors: Iterable<any>, message?: string): AggregateError;
    (errors: Iterable<any>, message?: string): AggregateError;
    readonly prototype: AggregateError;
}

declare var AggregateError: AggregateErrorConstructor;

/**
 * Represents the completion of an asynchronous operation
 */
interface PromiseConstructor {
    /**
     * The any function returns a promise that is fulfilled by the first given promise to be fulfilled, or rejected with an AggregateError containing an array of rejection reasons if all of the given promises are rejected. It resolves all elements of the passed iterable to promises as it runs this algorithm.
     * @param values An array or iterable of Promises.
     * @returns A new Promise.
     */
    any<T extends readonly unknown[] | []>(values: T): Promise<Awaited<T[number]>>;

    /**
     * The any function returns a promise that is fulfilled by the first given promise to be fulfilled, or rejected with an AggregateError containing an array of rejection reasons if all of the given promises are rejected. It resolves all elements of the passed iterable to promises as it runs this algorithm.
     * @param values An array or iterable of Promises.
     * @returns A new Promise.
     */
    any<T>(values: Iterable<T | PromiseLike<T>>): Promise<Awaited<T>>;
}

//========== lib.es2021.string.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface String {
    /**
     * Replace all instances of a substring in a string, using a regular expression or search string.
     * @param searchValue A string to search for.
     * @param replaceValue A string containing the text to replace for every successful match of searchValue in this string.
     */
    replaceAll(searchValue: string | RegExp, replaceValue: string): string;

    /**
     * Replace all instances of a substring in a string, using a regular expression or search string.
     * @param searchValue A string to search for.
     * @param replacer A function that returns the replacement text.
     */
    replaceAll(searchValue: string | RegExp, replacer: (substring: string, ...args: any[]) => string): string;
}

//========== lib.es2021.weakref.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2015.symbol.wellknown" />

interface WeakRef<T extends WeakKey> {
    readonly [Symbol.toStringTag]: "WeakRef";

    /**
     * Returns the WeakRef instance's target value, or undefined if the target value has been
     * reclaimed.
     * In es2023 the value can be either a symbol or an object, in previous versions only object is permissible.
     */
    deref(): T | undefined;
}

interface WeakRefConstructor {
    readonly prototype: WeakRef<any>;

    /**
     * Creates a WeakRef instance for the given target value.
     * In es2023 the value can be either a symbol or an object, in previous versions only object is permissible.
     * @param target The target value for the WeakRef instance.
     */
    new <T extends WeakKey>(target: T): WeakRef<T>;
}

declare var WeakRef: WeakRefConstructor;

interface FinalizationRegistry<T> {
    readonly [Symbol.toStringTag]: "FinalizationRegistry";

    /**
     * Registers a value with the registry.
     * In es2023 the value can be either a symbol or an object, in previous versions only object is permissible.
     * @param target The target value to register.
     * @param heldValue The value to pass to the finalizer for this value. This cannot be the
     * target value.
     * @param unregisterToken The token to pass to the unregister method to unregister the target
     * value. If not provided, the target cannot be unregistered.
     */
    register(target: WeakKey, heldValue: T, unregisterToken?: WeakKey): void;

    /**
     * Unregisters a value from the registry.
     * In es2023 the value can be either a symbol or an object, in previous versions only object is permissible.
     * @param unregisterToken The token that was used as the unregisterToken argument when calling
     * register to register the target value.
     */
    unregister(unregisterToken: WeakKey): boolean;
}

interface FinalizationRegistryConstructor {
    readonly prototype: FinalizationRegistry<any>;

    /**
     * Creates a finalization registry with an associated cleanup callback
     * @param cleanupCallback The callback to call after a value in the registry has been reclaimed.
     */
    new <T>(cleanupCallback: (heldValue: T) => void): FinalizationRegistry<T>;
}

declare var FinalizationRegistry: FinalizationRegistryConstructor;

//========== lib.es2021.intl.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


declare namespace Intl {
    interface DateTimeFormatPartTypesRegistry {
        fractionalSecond: any;
    }

    interface DateTimeFormatOptions {
        formatMatcher?: "basic" | "best fit" | "best fit" | undefined;
        dateStyle?: "full" | "long" | "medium" | "short" | undefined;
        timeStyle?: "full" | "long" | "medium" | "short" | undefined;
        dayPeriod?: "narrow" | "short" | "long" | undefined;
        fractionalSecondDigits?: 1 | 2 | 3 | undefined;
    }

    interface DateTimeRangeFormatPart extends DateTimeFormatPart {
        source: "startRange" | "endRange" | "shared";
    }

    interface DateTimeFormat {
        formatRange(startDate: Date | number | bigint, endDate: Date | number | bigint): string;
        formatRangeToParts(startDate: Date | number | bigint, endDate: Date | number | bigint): DateTimeRangeFormatPart[];
    }

    interface ResolvedDateTimeFormatOptions {
        formatMatcher?: "basic" | "best fit" | "best fit";
        dateStyle?: "full" | "long" | "medium" | "short";
        timeStyle?: "full" | "long" | "medium" | "short";
        hourCycle?: "h11" | "h12" | "h23" | "h24";
        dayPeriod?: "narrow" | "short" | "long";
        fractionalSecondDigits?: 1 | 2 | 3;
    }

    /**
     * The locale matching algorithm to use.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/ListFormat#parameters).
     */
    type ListFormatLocaleMatcher = "lookup" | "best fit";

    /**
     * The format of output message.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/ListFormat#parameters).
     */
    type ListFormatType = "conjunction" | "disjunction" | "unit";

    /**
     * The length of the formatted message.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/ListFormat#parameters).
     */
    type ListFormatStyle = "long" | "short" | "narrow";

    /**
     * An object with some or all properties of the `Intl.ListFormat` constructor `options` parameter.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/ListFormat#parameters).
     */
    interface ListFormatOptions {
        /** The locale matching algorithm to use. For information about this option, see [Intl page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_negotiation). */
        localeMatcher?: ListFormatLocaleMatcher | undefined;
        /** The format of output message. */
        type?: ListFormatType | undefined;
        /** The length of the internationalized message. */
        style?: ListFormatStyle | undefined;
    }

    interface ResolvedListFormatOptions {
        locale: string;
        style: ListFormatStyle;
        type: ListFormatType;
    }

    interface ListFormat {
        /**
         * Returns a string with a language-specific representation of the list.
         *
         * @param list - An iterable object, such as an [Array](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Array).
         *
         * @throws `TypeError` if `list` includes something other than the possible values.
         *
         * @returns {string} A language-specific formatted string representing the elements of the list.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/format).
         */
        format(list: Iterable<string>): string;

        /**
         * Returns an Array of objects representing the different components that can be used to format a list of values in a locale-aware fashion.
         *
         * @param list - An iterable object, such as an [Array](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Array), to be formatted according to a locale.
         *
         * @throws `TypeError` if `list` includes something other than the possible values.
         *
         * @returns {{ type: "element" | "literal", value: string; }[]} An Array of components which contains the formatted parts from the list.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/formatToParts).
         */
        formatToParts(list: Iterable<string>): { type: "element" | "literal"; value: string; }[];

        /**
         * Returns a new object with properties reflecting the locale and style
         * formatting options computed during the construction of the current
         * `Intl.ListFormat` object.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/resolvedOptions).
         */
        resolvedOptions(): ResolvedListFormatOptions;
    }

    const ListFormat: {
        prototype: ListFormat;

        /**
         * Creates [Intl.ListFormat](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat) objects that
         * enable language-sensitive list formatting.
         *
         * @param locales - A string with a [BCP 47 language tag](http://tools.ietf.org/html/rfc5646), or an array of such strings.
         *  For the general form and interpretation of the `locales` argument,
         *  see the [`Intl` page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_identification_and_negotiation).
         *
         * @param options - An [object](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/ListFormat#parameters)
         *  with some or all options of `ListFormatOptions`.
         *
         * @returns [Intl.ListFormatOptions](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat) object.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat).
         */
        new (locales?: LocalesArgument, options?: ListFormatOptions): ListFormat;

        /**
         * Returns an array containing those of the provided locales that are
         * supported in list formatting without having to fall back to the runtime's default locale.
         *
         * @param locales - A string with a [BCP 47 language tag](http://tools.ietf.org/html/rfc5646), or an array of such strings.
         *  For the general form and interpretation of the `locales` argument,
         *  see the [`Intl` page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_identification_and_negotiation).
         *
         * @param options - An [object](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/supportedLocalesOf#parameters).
         *  with some or all possible options.
         *
         * @returns An array of strings representing a subset of the given locale tags that are supported in list
         *  formatting without having to fall back to the runtime's default locale.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/ListFormat/supportedLocalesOf).
         */
        supportedLocalesOf(locales: LocalesArgument, options?: Pick<ListFormatOptions, "localeMatcher">): UnicodeBCP47LocaleIdentifier[];
    };
}

//========== lib.es2021.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2020" />
/// <reference lib="es2021.promise" />
/// <reference lib="es2021.string" />
/// <reference lib="es2021.weakref" />
/// <reference lib="es2021.intl" />

//========== lib.es2022.array.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface Array<T> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): T | undefined;
}

interface ReadonlyArray<T> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): T | undefined;
}

interface Int8Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface Uint8Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface Uint8ClampedArray<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface Int16Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface Uint16Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface Int32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface Uint32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface Float32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface Float64Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;
}

interface BigInt64Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): bigint | undefined;
}

interface BigUint64Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): bigint | undefined;
}

//========== lib.es2022.error.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2021.promise" />

interface ErrorOptions {
    cause?: unknown;
}

interface Error {
    cause?: unknown;
}

interface ErrorConstructor {
    new (message?: string, options?: ErrorOptions): Error;
    (message?: string, options?: ErrorOptions): Error;
}

interface EvalErrorConstructor {
    new (message?: string, options?: ErrorOptions): EvalError;
    (message?: string, options?: ErrorOptions): EvalError;
}

interface RangeErrorConstructor {
    new (message?: string, options?: ErrorOptions): RangeError;
    (message?: string, options?: ErrorOptions): RangeError;
}

interface ReferenceErrorConstructor {
    new (message?: string, options?: ErrorOptions): ReferenceError;
    (message?: string, options?: ErrorOptions): ReferenceError;
}

interface SyntaxErrorConstructor {
    new (message?: string, options?: ErrorOptions): SyntaxError;
    (message?: string, options?: ErrorOptions): SyntaxError;
}

interface TypeErrorConstructor {
    new (message?: string, options?: ErrorOptions): TypeError;
    (message?: string, options?: ErrorOptions): TypeError;
}

interface URIErrorConstructor {
    new (message?: string, options?: ErrorOptions): URIError;
    (message?: string, options?: ErrorOptions): URIError;
}

interface AggregateErrorConstructor {
    new (
        errors: Iterable<any>,
        message?: string,
        options?: ErrorOptions,
    ): AggregateError;
    (
        errors: Iterable<any>,
        message?: string,
        options?: ErrorOptions,
    ): AggregateError;
}

//========== lib.es2022.intl.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


declare namespace Intl {
    /**
     * An object with some or all properties of the `Intl.Segmenter` constructor `options` parameter.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter/Segmenter#parameters)
     */
    interface SegmenterOptions {
        /** The locale matching algorithm to use. For information about this option, see [Intl page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_negotiation). */
        localeMatcher?: "best fit" | "lookup" | undefined;
        /** The type of input to be split */
        granularity?: "grapheme" | "word" | "sentence" | undefined;
    }

    /**
     * The `Intl.Segmenter` object enables locale-sensitive text segmentation, enabling you to get meaningful items (graphemes, words or sentences) from a string.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter)
     */
    interface Segmenter {
        /**
         * Returns `Segments` object containing the segments of the input string, using the segmenter's locale and granularity.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter/segment)
         *
         * @param input - The text to be segmented as a `string`.
         *
         * @returns A new iterable Segments object containing the segments of the input string, using the segmenter's locale and granularity.
         */
        segment(input: string): Segments;
        /**
         * The `resolvedOptions()` method of `Intl.Segmenter` instances returns a new object with properties reflecting the options computed during initialization of this `Segmenter` object.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter/resolvedOptions)
         */
        resolvedOptions(): ResolvedSegmenterOptions;
    }

    interface ResolvedSegmenterOptions {
        locale: string;
        granularity: "grapheme" | "word" | "sentence";
    }

    interface SegmentIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
        [Symbol.iterator](): SegmentIterator<T>;
    }

    /**
     * A `Segments` object is an iterable collection of the segments of a text string. It is returned by a call to the `segment()` method of an `Intl.Segmenter` object.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter/segment/Segments)
     */
    interface Segments {
        /**
         * Returns an object describing the segment in the original string that includes the code unit at a specified index.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter/segment/Segments/containing)
         *
         * @param codeUnitIndex - A number specifying the index of the code unit in the original input string. If the value is omitted, it defaults to `0`.
         */
        containing(codeUnitIndex?: number): SegmentData | undefined;

        /** Returns an iterator to iterate over the segments. */
        [Symbol.iterator](): SegmentIterator<SegmentData>;
    }

    interface SegmentData {
        /** A string containing the segment extracted from the original input string. */
        segment: string;
        /** The code unit index in the original input string at which the segment begins. */
        index: number;
        /** The complete input string that was segmented. */
        input: string;
        /**
         * A boolean value only if granularity is "word"; otherwise, undefined.
         * If granularity is "word", then isWordLike is true when the segment is word-like (i.e., consists of letters/numbers/ideographs/etc.); otherwise, false.
         */
        isWordLike?: boolean;
    }

    /**
     * The `Intl.Segmenter` object enables locale-sensitive text segmentation, enabling you to get meaningful items (graphemes, words or sentences) from a string.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter)
     */
    const Segmenter: {
        prototype: Segmenter;

        /**
         * Creates a new `Intl.Segmenter` object.
         *
         * @param locales - A string with a [BCP 47 language tag](http://tools.ietf.org/html/rfc5646), or an array of such strings.
         *  For the general form and interpretation of the `locales` argument,
         *  see the [`Intl` page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_identification_and_negotiation).
         *
         * @param options - An [object](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter/Segmenter#parameters)
         *  with some or all options of `SegmenterOptions`.
         *
         * @returns [Intl.Segmenter](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segments) object.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter).
         */
        new (locales?: LocalesArgument, options?: SegmenterOptions): Segmenter;

        /**
         * Returns an array containing those of the provided locales that are supported without having to fall back to the runtime's default locale.
         *
         * @param locales - A string with a [BCP 47 language tag](http://tools.ietf.org/html/rfc5646), or an array of such strings.
         *  For the general form and interpretation of the `locales` argument,
         *  see the [`Intl` page](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_identification_and_negotiation).
         *
         * @param options An [object](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter/supportedLocalesOf#parameters).
         *  with some or all possible options.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter/supportedLocalesOf)
         */
        supportedLocalesOf(locales: LocalesArgument, options?: Pick<SegmenterOptions, "localeMatcher">): UnicodeBCP47LocaleIdentifier[];
    };

    /**
     * Returns a sorted array of the supported collation, calendar, currency, numbering system, timezones, and units by the implementation.
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/supportedValuesOf)
     *
     * @param key A string indicating the category of values to return.
     * @returns A sorted array of the supported values.
     */
    function supportedValuesOf(key: "calendar" | "collation" | "currency" | "numberingSystem" | "timeZone" | "unit"): string[];
}

//========== lib.es2022.object.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


interface ObjectConstructor {
    /**
     * Determines whether an object has a property with the specified name.
     * @param o An object.
     * @param v A property name.
     */
    hasOwn(o: object, v: PropertyKey): boolean;
}
