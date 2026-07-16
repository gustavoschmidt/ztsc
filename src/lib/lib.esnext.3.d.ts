
//========== lib.es2022.regexp.d.ts ==========
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
    indices?: RegExpIndicesArray;
}

interface RegExpExecArray {
    indices?: RegExpIndicesArray;
}

interface RegExpIndicesArray extends Array<[number, number] | undefined> {
    groups?: {
        [key: string]: [number, number];
    };
}

interface RegExp {
    /**
     * Returns a Boolean value indicating the state of the hasIndices flag (d) used with a regular expression.
     * Default is false. Read-only.
     */
    readonly hasIndices: boolean;
}

//========== lib.es2022.string.d.ts ==========
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
     * Returns a new String consisting of the single UTF-16 code unit located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): string | undefined;
}

//========== lib.es2022.d.ts ==========
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


/// <reference lib="es2021" />
/// <reference lib="es2022.array" />
/// <reference lib="es2022.error" />
/// <reference lib="es2022.intl" />
/// <reference lib="es2022.object" />
/// <reference lib="es2022.regexp" />
/// <reference lib="es2022.string" />

//========== lib.es2023.array.d.ts ==========
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
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends T>(predicate: (value: T, index: number, array: T[]) => value is S, thisArg?: any): S | undefined;
    findLast(predicate: (value: T, index: number, array: T[]) => unknown, thisArg?: any): T | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(predicate: (value: T, index: number, array: T[]) => unknown, thisArg?: any): number;

    /**
     * Returns a copy of an array with its elements reversed.
     */
    toReversed(): T[];

    /**
     * Returns a copy of an array with its elements sorted.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending, UTF-16 code unit order.
     * ```ts
     * [11, 2, 22, 1].toSorted((a, b) => a - b) // [1, 2, 11, 22]
     * ```
     */
    toSorted(compareFn?: (a: T, b: T) => number): T[];

    /**
     * Copies an array and removes elements and, if necessary, inserts new elements in their place. Returns the copied array.
     * @param start The zero-based location in the array from which to start removing elements.
     * @param deleteCount The number of elements to remove.
     * @param items Elements to insert into the copied array in place of the deleted elements.
     * @returns The copied array.
     */
    toSpliced(start: number, deleteCount: number, ...items: T[]): T[];

    /**
     * Copies an array and removes elements while returning the remaining elements.
     * @param start The zero-based location in the array from which to start removing elements.
     * @param deleteCount The number of elements to remove.
     * @returns A copy of the original array with the remaining elements.
     */
    toSpliced(start: number, deleteCount?: number): T[];

    /**
     * Copies an array, then overwrites the value at the provided index with the
     * given value. If the index is negative, then it replaces from the end
     * of the array.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to write into the copied array.
     * @returns The copied array with the updated value.
     */
    with(index: number, value: T): T[];
}

interface ReadonlyArray<T> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends T>(
        predicate: (value: T, index: number, array: readonly T[]) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (value: T, index: number, array: readonly T[]) => unknown,
        thisArg?: any,
    ): T | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (value: T, index: number, array: readonly T[]) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copied array with all of its elements reversed.
     */
    toReversed(): T[];

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending, UTF-16 code unit order.
     * ```ts
     * [11, 2, 22, 1].toSorted((a, b) => a - b) // [1, 2, 11, 22]
     * ```
     */
    toSorted(compareFn?: (a: T, b: T) => number): T[];

    /**
     * Copies an array and removes elements while, if necessary, inserting new elements in their place, returning the remaining elements.
     * @param start The zero-based location in the array from which to start removing elements.
     * @param deleteCount The number of elements to remove.
     * @param items Elements to insert into the copied array in place of the deleted elements.
     * @returns A copy of the original array with the remaining elements.
     */
    toSpliced(start: number, deleteCount: number, ...items: T[]): T[];

    /**
     * Copies an array and removes elements while returning the remaining elements.
     * @param start The zero-based location in the array from which to start removing elements.
     * @param deleteCount The number of elements to remove.
     * @returns A copy of the original array with the remaining elements.
     */
    toSpliced(start: number, deleteCount?: number): T[];

    /**
     * Copies an array, then overwrites the value at the provided index with the
     * given value. If the index is negative, then it replaces from the end
     * of the array
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: T): T[];
}

interface Int8Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (value: number, index: number, array: this) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (value: number, index: number, array: this) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Int8Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Int8Array.from([11, 2, 22, 1]);
     * myNums.toSorted((a, b) => a - b) // Int8Array(4) [1, 2, 11, 22]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Int8Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Int8Array<ArrayBuffer>;
}

interface Uint8Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (value: number, index: number, array: this) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (value: number, index: number, array: this) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Uint8Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Uint8Array.from([11, 2, 22, 1]);
     * myNums.toSorted((a, b) => a - b) // Uint8Array(4) [1, 2, 11, 22]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Uint8Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Uint8Array<ArrayBuffer>;
}

interface Uint8ClampedArray<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Uint8ClampedArray<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Uint8ClampedArray.from([11, 2, 22, 1]);
     * myNums.toSorted((a, b) => a - b) // Uint8ClampedArray(4) [1, 2, 11, 22]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Uint8ClampedArray<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Uint8ClampedArray<ArrayBuffer>;
}

interface Int16Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (value: number, index: number, array: this) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (value: number, index: number, array: this) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Int16Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Int16Array.from([11, 2, -22, 1]);
     * myNums.toSorted((a, b) => a - b) // Int16Array(4) [-22, 1, 2, 11]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Int16Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Int16Array<ArrayBuffer>;
}

interface Uint16Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Uint16Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Uint16Array.from([11, 2, 22, 1]);
     * myNums.toSorted((a, b) => a - b) // Uint16Array(4) [1, 2, 11, 22]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Uint16Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Uint16Array<ArrayBuffer>;
}

interface Int32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (value: number, index: number, array: this) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (value: number, index: number, array: this) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Int32Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Int32Array.from([11, 2, -22, 1]);
     * myNums.toSorted((a, b) => a - b) // Int32Array(4) [-22, 1, 2, 11]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Int32Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Int32Array<ArrayBuffer>;
}

interface Uint32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Uint32Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Uint32Array.from([11, 2, 22, 1]);
     * myNums.toSorted((a, b) => a - b) // Uint32Array(4) [1, 2, 11, 22]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Uint32Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Uint32Array<ArrayBuffer>;
}

interface Float32Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Float32Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Float32Array.from([11.25, 2, -22.5, 1]);
     * myNums.toSorted((a, b) => a - b) // Float32Array(4) [-22.5, 1, 2, 11.5]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Float32Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Float32Array<ArrayBuffer>;
}

interface Float64Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Float64Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Float64Array.from([11.25, 2, -22.5, 1]);
     * myNums.toSorted((a, b) => a - b) // Float64Array(4) [-22.5, 1, 2, 11.5]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Float64Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Float64Array<ArrayBuffer>;
}

interface BigInt64Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends bigint>(
        predicate: (
            value: bigint,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (
            value: bigint,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): bigint | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (
            value: bigint,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): BigInt64Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = BigInt64Array.from([11n, 2n, -22n, 1n]);
     * myNums.toSorted((a, b) => Number(a - b)) // BigInt64Array(4) [-22n, 1n, 2n, 11n]
     * ```
     */
    toSorted(compareFn?: (a: bigint, b: bigint) => number): BigInt64Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given bigint at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: bigint): BigInt64Array<ArrayBuffer>;
}

interface BigUint64Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends bigint>(
        predicate: (
            value: bigint,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (
            value: bigint,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): bigint | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (
            value: bigint,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): BigUint64Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = BigUint64Array.from([11n, 2n, 22n, 1n]);
     * myNums.toSorted((a, b) => Number(a - b)) // BigUint64Array(4) [1n, 2n, 11n, 22n]
     * ```
     */
    toSorted(compareFn?: (a: bigint, b: bigint) => number): BigUint64Array<ArrayBuffer>;

    /**
     * Copies the array and inserts the given bigint at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: bigint): BigUint64Array<ArrayBuffer>;
}

//========== lib.es2023.collection.d.ts ==========
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


interface WeakKeyTypes {
    symbol: symbol;
}

//========== lib.es2023.intl.d.ts ==========
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
    interface NumberFormatOptionsUseGroupingRegistry {
        min2: never;
        auto: never;
        always: never;
    }

    interface NumberFormatOptionsSignDisplayRegistry {
        negative: never;
    }

    interface NumberFormatRangePartTypeRegistry extends NumberFormatPartTypeRegistry {
        approximatelySign: never;
    }

    type NumberFormatRangePartTypes = keyof NumberFormatRangePartTypeRegistry;

    interface NumberFormatOptions {
        roundingPriority?: "auto" | "morePrecision" | "lessPrecision" | undefined;
        roundingIncrement?: 1 | 2 | 5 | 10 | 20 | 25 | 50 | 100 | 200 | 250 | 500 | 1000 | 2000 | 2500 | 5000 | undefined;
        roundingMode?: "ceil" | "floor" | "expand" | "trunc" | "halfCeil" | "halfFloor" | "halfExpand" | "halfTrunc" | "halfEven" | undefined;
        trailingZeroDisplay?: "auto" | "stripIfInteger" | undefined;
    }

    interface ResolvedNumberFormatOptions {
        roundingPriority: "auto" | "morePrecision" | "lessPrecision";
        roundingMode: "ceil" | "floor" | "expand" | "trunc" | "halfCeil" | "halfFloor" | "halfExpand" | "halfTrunc" | "halfEven";
        roundingIncrement: 1 | 2 | 5 | 10 | 20 | 25 | 50 | 100 | 200 | 250 | 500 | 1000 | 2000 | 2500 | 5000;
        trailingZeroDisplay: "auto" | "stripIfInteger";
    }

    interface NumberRangeFormatPart {
        type: NumberFormatRangePartTypes;
        value: string;
        source: "startRange" | "endRange" | "shared";
    }

    type StringNumericLiteral = `${number}` | "Infinity" | "-Infinity" | "+Infinity";

    interface NumberFormat {
        format(value: number | bigint | StringNumericLiteral): string;
        formatToParts(value: number | bigint | StringNumericLiteral): NumberFormatPart[];
        formatRange(start: number | bigint | StringNumericLiteral, end: number | bigint | StringNumericLiteral): string;
        formatRangeToParts(start: number | bigint | StringNumericLiteral, end: number | bigint | StringNumericLiteral): NumberRangeFormatPart[];
    }
}

//========== lib.es2023.d.ts ==========
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


/// <reference lib="es2022" />
/// <reference lib="es2023.array" />
/// <reference lib="es2023.collection" />
/// <reference lib="es2023.intl" />

//========== lib.es2024.arraybuffer.d.ts ==========
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


interface ArrayBuffer {
    /**
     * If this ArrayBuffer is resizable, returns the maximum byte length given during construction; returns the byte length if not.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/ArrayBuffer/maxByteLength)
     */
    get maxByteLength(): number;

    /**
     * Returns true if this ArrayBuffer can be resized.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/ArrayBuffer/resizable)
     */
    get resizable(): boolean;

    /**
     * Resizes the ArrayBuffer to the specified size (in bytes).
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/ArrayBuffer/resize)
     */
    resize(newByteLength?: number): void;

    /**
     * Returns a boolean indicating whether or not this buffer has been detached (transferred).
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/ArrayBuffer/detached)
     */
    get detached(): boolean;

    /**
     * Creates a new ArrayBuffer with the same byte content as this buffer, then detaches this buffer.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/ArrayBuffer/transfer)
     */
    transfer(newByteLength?: number): ArrayBuffer;

    /**
     * Creates a new non-resizable ArrayBuffer with the same byte content as this buffer, then detaches this buffer.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/ArrayBuffer/transferToFixedLength)
     */
    transferToFixedLength(newByteLength?: number): ArrayBuffer;
}

interface ArrayBufferConstructor {
    new (byteLength: number, options?: { maxByteLength?: number; }): ArrayBuffer;
}

//========== lib.es2024.collection.d.ts ==========
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


interface MapConstructor {
    /**
     * Groups members of an iterable according to the return value of the passed callback.
     * @param items An iterable.
     * @param keySelector A callback which will be invoked for each item in items.
     */
    groupBy<K, T>(
        items: Iterable<T>,
        keySelector: (item: T, index: number) => K,
    ): Map<K, T[]>;
}

//========== lib.es2024.object.d.ts ==========
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
     * Groups members of an iterable according to the return value of the passed callback.
     * @param items An iterable.
     * @param keySelector A callback which will be invoked for each item in items.
     */
    groupBy<K extends PropertyKey, T>(
        items: Iterable<T>,
        keySelector: (item: T, index: number) => K,
    ): Partial<Record<K, T[]>>;
}

//========== lib.es2024.promise.d.ts ==========
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


interface PromiseWithResolvers<T> {
    promise: Promise<T>;
    resolve: (value: T | PromiseLike<T>) => void;
    reject: (reason?: any) => void;
}

interface PromiseConstructor {
    /**
     * Creates a new Promise and returns it in an object, along with its resolve and reject functions.
     * @returns An object with the properties `promise`, `resolve`, and `reject`.
     *
     * ```ts
     * const { promise, resolve, reject } = Promise.withResolvers<T>();
     * ```
     */
    withResolvers<T>(): PromiseWithResolvers<T>;
}

//========== lib.es2024.regexp.d.ts ==========
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


interface RegExp {
    /**
     * Returns a Boolean value indicating the state of the unicodeSets flag (v) used with a regular expression.
     * Default is false. Read-only.
     */
    readonly unicodeSets: boolean;
}

//========== lib.es2024.sharedmemory.d.ts ==========
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
     * A non-blocking, asynchronous version of wait which is usable on the main thread.
     * Waits asynchronously on a shared memory location and returns a Promise
     * @param typedArray A shared Int32Array or BigInt64Array.
     * @param index The position in the typedArray to wait on.
     * @param value The expected value to test.
     * @param [timeout] The expected value to test.
     */
    waitAsync(typedArray: Int32Array, index: number, value: number, timeout?: number): { async: false; value: "not-equal" | "timed-out"; } | { async: true; value: Promise<"ok" | "timed-out">; };

    /**
     * A non-blocking, asynchronous version of wait which is usable on the main thread.
     * Waits asynchronously on a shared memory location and returns a Promise
     * @param typedArray A shared Int32Array or BigInt64Array.
     * @param index The position in the typedArray to wait on.
     * @param value The expected value to test.
     * @param [timeout] The expected value to test.
     */
    waitAsync(typedArray: BigInt64Array, index: number, value: bigint, timeout?: number): { async: false; value: "not-equal" | "timed-out"; } | { async: true; value: Promise<"ok" | "timed-out">; };
}

interface SharedArrayBuffer {
    /**
     * Returns true if this SharedArrayBuffer can be grown.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer/growable)
     */
    get growable(): boolean;

    /**
     * If this SharedArrayBuffer is growable, returns the maximum byte length given during construction; returns the byte length if not.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer/maxByteLength)
     */
    get maxByteLength(): number;

    /**
     * Grows the SharedArrayBuffer to the specified size (in bytes).
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer/grow)
     */
    grow(newByteLength?: number): void;
}

interface SharedArrayBufferConstructor {
    new (byteLength: number, options?: { maxByteLength?: number; }): SharedArrayBuffer;
}

//========== lib.es2024.string.d.ts ==========
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
     * Returns true if all leading surrogates and trailing surrogates appear paired and in order.
     */
    isWellFormed(): boolean;

    /**
     * Returns a string where all lone or out-of-order surrogates have been replaced by the Unicode replacement character (U+FFFD).
     */
    toWellFormed(): string;
}

//========== lib.es2024.d.ts ==========
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


/// <reference lib="es2023" />
/// <reference lib="es2024.arraybuffer" />
/// <reference lib="es2024.collection" />
/// <reference lib="es2024.object" />
/// <reference lib="es2024.promise" />
/// <reference lib="es2024.regexp" />
/// <reference lib="es2024.sharedmemory" />
/// <reference lib="es2024.string" />

//========== lib.es2025.collection.d.ts ==========
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


/// <reference lib="es2024.collection" />

interface ReadonlySetLike<T> {
    /**
     * Despite its name, returns an iterator of the values in the set-like.
     */
    keys(): Iterator<T>;
    /**
     * @returns a boolean indicating whether an element with the specified value exists in the set-like or not.
     */
    has(value: T): boolean;
    /**
     * @returns the number of (unique) elements in the set-like.
     */
    readonly size: number;
}

interface Set<T> {
    /**
     * @returns a new Set containing all the elements in this Set and also all the elements in the argument.
     */
    union<U>(other: ReadonlySetLike<U>): Set<T | U>;
    /**
     * @returns a new Set containing all the elements which are both in this Set and in the argument.
     */
    intersection<U>(other: ReadonlySetLike<U>): Set<T & U>;
    /**
     * @returns a new Set containing all the elements in this Set which are not also in the argument.
     */
    difference<U>(other: ReadonlySetLike<U>): Set<T>;
    /**
     * @returns a new Set containing all the elements which are in either this Set or in the argument, but not in both.
     */
    symmetricDifference<U>(other: ReadonlySetLike<U>): Set<T | U>;
    /**
     * @returns a boolean indicating whether all the elements in this Set are also in the argument.
     */
    isSubsetOf(other: ReadonlySetLike<unknown>): boolean;
    /**
     * @returns a boolean indicating whether all the elements in the argument are also in this Set.
     */
    isSupersetOf(other: ReadonlySetLike<unknown>): boolean;
    /**
     * @returns a boolean indicating whether this Set has no elements in common with the argument.
     */
    isDisjointFrom(other: ReadonlySetLike<unknown>): boolean;
}

interface ReadonlySet<T> {
    /**
     * @returns a new Set containing all the elements in this Set and also all the elements in the argument.
     */
    union<U>(other: ReadonlySetLike<U>): Set<T | U>;
    /**
     * @returns a new Set containing all the elements which are both in this Set and in the argument.
     */
    intersection<U>(other: ReadonlySetLike<U>): Set<T & U>;
    /**
     * @returns a new Set containing all the elements in this Set which are not also in the argument.
     */
    difference<U>(other: ReadonlySetLike<U>): Set<T>;
    /**
     * @returns a new Set containing all the elements which are in either this Set or in the argument, but not in both.
     */
    symmetricDifference<U>(other: ReadonlySetLike<U>): Set<T | U>;
    /**
     * @returns a boolean indicating whether all the elements in this Set are also in the argument.
     */
    isSubsetOf(other: ReadonlySetLike<unknown>): boolean;
    /**
     * @returns a boolean indicating whether all the elements in the argument are also in this Set.
     */
    isSupersetOf(other: ReadonlySetLike<unknown>): boolean;
    /**
     * @returns a boolean indicating whether this Set has no elements in common with the argument.
     */
    isDisjointFrom(other: ReadonlySetLike<unknown>): boolean;
}

//========== lib.es2025.float16.d.ts ==========
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

/**
 * A typed array of 16-bit float values. The contents are initialized to 0. If the requested number
 * of bytes could not be allocated an exception is raised.
 */
interface Float16Array<TArrayBuffer extends ArrayBufferLike = ArrayBufferLike> {
    /**
     * The size in bytes of each element in the array.
     */
    readonly BYTES_PER_ELEMENT: number;

    /**
     * The ArrayBuffer instance referenced by the array.
     */
    readonly buffer: TArrayBuffer;

    /**
     * The length in bytes of the array.
     */
    readonly byteLength: number;

    /**
     * The offset in bytes of the array.
     */
    readonly byteOffset: number;

    /**
     * Returns the item located at the specified index.
     * @param index The zero-based index of the desired code unit. A negative index will count back from the last item.
     */
    at(index: number): number | undefined;

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

    /**
     * Determines whether all the members of an array satisfy the specified test.
     * @param predicate A function that accepts up to three arguments. The every method calls
     * the predicate function for each element in the array until the predicate returns a value
     * which is coercible to the Boolean value false, or until the end of the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    every(predicate: (value: number, index: number, array: this) => unknown, thisArg?: any): boolean;

    /**
     * Changes all array elements from `start` to `end` index to a static `value` and returns the modified array
     * @param value value to fill array section with
     * @param start index to start filling the array at. If start is negative, it is treated as
     * length+start where length is the length of the array.
     * @param end index to stop filling the array at. If end is negative, it is treated as
     * length+end.
     */
    fill(value: number, start?: number, end?: number): this;

    /**
     * Returns the elements of an array that meet the condition specified in a callback function.
     * @param predicate A function that accepts up to three arguments. The filter method calls
     * the predicate function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    filter(predicate: (value: number, index: number, array: this) => any, thisArg?: any): Float16Array<ArrayBuffer>;

    /**
     * Returns the value of the first element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate find calls predicate once for each element of the array, in ascending
     * order, until it finds one where predicate returns true. If such an element is found, find
     * immediately returns that element value. Otherwise, find returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    find(predicate: (value: number, index: number, obj: this) => boolean, thisArg?: any): number | undefined;

    /**
     * Returns the index of the first element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate find calls predicate once for each element of the array, in ascending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findIndex immediately returns that element index. Otherwise, findIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findIndex(predicate: (value: number, index: number, obj: this) => boolean, thisArg?: any): number;

    /**
     * Returns the value of the last element in the array where predicate is true, and undefined
     * otherwise.
     * @param predicate findLast calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found, findLast
     * immediately returns that element value. Otherwise, findLast returns undefined.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLast<S extends number>(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => value is S,
        thisArg?: any,
    ): S | undefined;
    findLast(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number | undefined;

    /**
     * Returns the index of the last element in the array where predicate is true, and -1
     * otherwise.
     * @param predicate findLastIndex calls predicate once for each element of the array, in descending
     * order, until it finds one where predicate returns true. If such an element is found,
     * findLastIndex immediately returns that element index. Otherwise, findLastIndex returns -1.
     * @param thisArg If provided, it will be used as the this value for each invocation of
     * predicate. If it is not provided, undefined is used instead.
     */
    findLastIndex(
        predicate: (
            value: number,
            index: number,
            array: this,
        ) => unknown,
        thisArg?: any,
    ): number;

    /**
     * Performs the specified action for each element in an array.
     * @param callbackfn A function that accepts up to three arguments. forEach calls the
     * callbackfn function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the callbackfn function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    forEach(callbackfn: (value: number, index: number, array: this) => void, thisArg?: any): void;

    /**
     * Determines whether an array includes a certain element, returning true or false as appropriate.
     * @param searchElement The element to search for.
     * @param fromIndex The position in this array at which to begin searching for searchElement.
     */
    includes(searchElement: number, fromIndex?: number): boolean;

    /**
     * Returns the index of the first occurrence of a value in an array.
     * @param searchElement The value to locate in the array.
     * @param fromIndex The array index at which to begin the search. If fromIndex is omitted, the
     * search starts at index 0.
     */
    indexOf(searchElement: number, fromIndex?: number): number;

    /**
     * Adds all the elements of an array separated by the specified separator string.
     * @param separator A string used to separate one element of an array from the next in the
     * resulting String. If omitted, the array elements are separated with a comma.
     */
    join(separator?: string): string;

    /**
     * Returns the index of the last occurrence of a value in an array.
     * @param searchElement The value to locate in the array.
     * @param fromIndex The array index at which to begin the search. If fromIndex is omitted, the
     * search starts at index 0.
     */
    lastIndexOf(searchElement: number, fromIndex?: number): number;

    /**
     * The length of the array.
     */
    readonly length: number;

    /**
     * Calls a defined callback function on each element of an array, and returns an array that
     * contains the results.
     * @param callbackfn A function that accepts up to three arguments. The map method calls the
     * callbackfn function one time for each element in the array.
     * @param thisArg An object to which the this keyword can refer in the callbackfn function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    map(callbackfn: (value: number, index: number, array: this) => number, thisArg?: any): Float16Array<ArrayBuffer>;

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
    reduce(callbackfn: (previousValue: number, currentValue: number, currentIndex: number, array: this) => number): number;
    reduce(callbackfn: (previousValue: number, currentValue: number, currentIndex: number, array: this) => number, initialValue: number): number;

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
    reduce<U>(callbackfn: (previousValue: U, currentValue: number, currentIndex: number, array: this) => U, initialValue: U): U;

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
    reduceRight(callbackfn: (previousValue: number, currentValue: number, currentIndex: number, array: this) => number): number;
    reduceRight(callbackfn: (previousValue: number, currentValue: number, currentIndex: number, array: this) => number, initialValue: number): number;

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
    reduceRight<U>(callbackfn: (previousValue: U, currentValue: number, currentIndex: number, array: this) => U, initialValue: U): U;

    /**
     * Reverses the elements in an Array.
     */
    reverse(): this;

    /**
     * Sets a value or an array of values.
     * @param array A typed or untyped array of values to set.
     * @param offset The index in the current array at which the values are to be written.
     */
    set(array: ArrayLike<number>, offset?: number): void;

    /**
     * Returns a section of an array.
     * @param start The beginning of the specified portion of the array.
     * @param end The end of the specified portion of the array. This is exclusive of the element at the index 'end'.
     */
    slice(start?: number, end?: number): Float16Array<ArrayBuffer>;

    /**
     * Determines whether the specified callback function returns true for any element of an array.
     * @param predicate A function that accepts up to three arguments. The some method calls
     * the predicate function for each element in the array until the predicate returns a value
     * which is coercible to the Boolean value true, or until the end of the array.
     * @param thisArg An object to which the this keyword can refer in the predicate function.
     * If thisArg is omitted, undefined is used as the this value.
     */
    some(predicate: (value: number, index: number, array: this) => unknown, thisArg?: any): boolean;

    /**
     * Sorts an array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if first argument is less than second argument, zero if they're equal and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * [11,2,22,1].sort((a, b) => a - b)
     * ```
     */
    sort(compareFn?: (a: number, b: number) => number): this;

    /**
     * Gets a new Float16Array view of the ArrayBuffer store for this array, referencing the elements
     * at begin, inclusive, up to end, exclusive.
     * @param begin The index of the beginning of the array.
     * @param end The index of the end of the array.
     */
    subarray(begin?: number, end?: number): Float16Array<TArrayBuffer>;

    /**
     * Converts a number to a string by using the current locale.
     */
    toLocaleString(locales?: string | string[], options?: Intl.NumberFormatOptions): string;

    /**
     * Copies the array and returns the copy with the elements in reverse order.
     */
    toReversed(): Float16Array<ArrayBuffer>;

    /**
     * Copies and sorts the array.
     * @param compareFn Function used to determine the order of the elements. It is expected to return
     * a negative value if the first argument is less than the second argument, zero if they're equal, and a positive
     * value otherwise. If omitted, the elements are sorted in ascending order.
     * ```ts
     * const myNums = Float16Array.from([11.25, 2, -22.5, 1]);
     * myNums.toSorted((a, b) => a - b) // Float16Array(4) [-22.5, 1, 2, 11.5]
     * ```
     */
    toSorted(compareFn?: (a: number, b: number) => number): Float16Array<ArrayBuffer>;

    /**
     * Returns a string representation of an array.
     */
    toString(): string;

    /** Returns the primitive value of the specified object. */
    valueOf(): this;

    /**
     * Copies the array and inserts the given number at the provided index.
     * @param index The index of the value to overwrite. If the index is
     * negative, then it replaces from the end of the array.
     * @param value The value to insert into the copied array.
     * @returns A copy of the original array with the inserted value.
     */
    with(index: number, value: number): Float16Array<ArrayBuffer>;

    [index: number]: number;

    [Symbol.iterator](): ArrayIterator<number>;

    /**
     * Returns an array of key, value pairs for every entry in the array
     */
    entries(): ArrayIterator<[number, number]>;

    /**
     * Returns an list of keys in the array
     */
    keys(): ArrayIterator<number>;

    /**
     * Returns an list of values in the array
     */
    values(): ArrayIterator<number>;

    readonly [Symbol.toStringTag]: "Float16Array";
}

interface Float16ArrayConstructor {
    readonly prototype: Float16Array<ArrayBufferLike>;
    new (length?: number): Float16Array<ArrayBuffer>;
    new (array: ArrayLike<number> | Iterable<number>): Float16Array<ArrayBuffer>;
    new <TArrayBuffer extends ArrayBufferLike = ArrayBuffer>(buffer: TArrayBuffer, byteOffset?: number, length?: number): Float16Array<TArrayBuffer>;
    new (buffer: ArrayBuffer, byteOffset?: number, length?: number): Float16Array<ArrayBuffer>;
    new (array: ArrayLike<number> | ArrayBuffer): Float16Array<ArrayBuffer>;

    /**
     * The size in bytes of each element in the array.
     */
    readonly BYTES_PER_ELEMENT: number;

    /**
     * Returns a new array from a set of elements.
     * @param items A set of elements to include in the new array object.
     */
    of(...items: number[]): Float16Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param arrayLike An array-like object to convert to an array.
     */
    from(arrayLike: ArrayLike<number>): Float16Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param arrayLike An array-like object to convert to an array.
     * @param mapfn A mapping function to call on every element of the array.
     * @param thisArg Value of 'this' used to invoke the mapfn.
     */
    from<T>(arrayLike: ArrayLike<T>, mapfn: (v: T, k: number) => number, thisArg?: any): Float16Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param elements An iterable object to convert to an array.
     */
    from(elements: Iterable<number>): Float16Array<ArrayBuffer>;

    /**
     * Creates an array from an array-like or iterable object.
     * @param elements An iterable object to convert to an array.
     * @param mapfn A mapping function to call on every element of the array.
     * @param thisArg Value of 'this' used to invoke the mapfn.
     */
    from<T>(elements: Iterable<T>, mapfn?: (v: T, k: number) => number, thisArg?: any): Float16Array<ArrayBuffer>;
}
declare var Float16Array: Float16ArrayConstructor;

interface Math {
    /**
     * Returns the nearest half precision float representation of a number.
     * @param x A numeric expression.
     */
    f16round(x: number): number;
}

interface DataView<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Gets the Float16 value at the specified byte offset from the start of the view. There is
     * no alignment constraint; multi-byte values may be fetched from any offset.
     * @param byteOffset The place in the buffer at which the value should be retrieved.
     * @param littleEndian If false or undefined, a big-endian value should be read.
     */
    getFloat16(byteOffset: number, littleEndian?: boolean): number;

    /**
     * Stores an Float16 value at the specified byte offset from the start of the view.
     * @param byteOffset The place in the buffer at which the value should be set.
     * @param value The value to set.
     * @param littleEndian If false or undefined, a big-endian value should be written.
     */
    setFloat16(byteOffset: number, value: number, littleEndian?: boolean): void;
}

//========== lib.es2025.intl.d.ts ==========
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
     * The locale matching algorithm to use.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_negotiation).
     */
    type DurationFormatLocaleMatcher = "lookup" | "best fit";

    /**
     * The style of the formatted duration.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/DurationFormat#style).
     */
    type DurationFormatStyle = "long" | "short" | "narrow" | "digital";

    /**
     * Whether to always display a unit, or only if it is non-zero.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/DurationFormat#display).
     */
    type DurationFormatDisplayOption = "always" | "auto";

    /**
     * Value of the `unit` property in duration objects
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/format#duration).
     */
    type DurationFormatUnit =
        | "years"
        | "months"
        | "weeks"
        | "days"
        | "hours"
        | "minutes"
        | "seconds"
        | "milliseconds"
        | "microseconds"
        | "nanoseconds";

    type DurationFormatUnitSingular =
        | "year"
        | "month"
        | "week"
        | "day"
        | "hour"
        | "minute"
        | "second"
        | "millisecond"
        | "microsecond"
        | "nanosecond";

    /**
     * An object representing the relative time format in parts
     * that can be used for custom locale-aware formatting.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/formatToParts).
     */
    type DurationFormatPart =
        | {
            type: "literal";
            value: string;
            unit?: DurationFormatUnitSingular;
        }
        | {
            type: Exclude<NumberFormatPartTypes, "literal">;
            value: string;
            unit: DurationFormatUnitSingular;
        };

    /**
     * An object with some or all properties of the `Intl.DurationFormat` constructor `options` parameter.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/DurationFormat#parameters)
     */
    interface DurationFormatOptions {
        localeMatcher?: DurationFormatLocaleMatcher | undefined;
        numberingSystem?: string | undefined;
        style?: DurationFormatStyle | undefined;
        years?: "long" | "short" | "narrow" | undefined;
        yearsDisplay?: DurationFormatDisplayOption | undefined;
        months?: "long" | "short" | "narrow" | undefined;
        monthsDisplay?: DurationFormatDisplayOption | undefined;
        weeks?: "long" | "short" | "narrow" | undefined;
        weeksDisplay?: DurationFormatDisplayOption | undefined;
        days?: "long" | "short" | "narrow" | undefined;
        daysDisplay?: DurationFormatDisplayOption | undefined;
        hours?: "long" | "short" | "narrow" | "numeric" | "2-digit" | undefined;
        hoursDisplay?: DurationFormatDisplayOption | undefined;
        minutes?: "long" | "short" | "narrow" | "numeric" | "2-digit" | undefined;
        minutesDisplay?: DurationFormatDisplayOption | undefined;
        seconds?: "long" | "short" | "narrow" | "numeric" | "2-digit" | undefined;
        secondsDisplay?: DurationFormatDisplayOption | undefined;
        milliseconds?: "long" | "short" | "narrow" | "numeric" | undefined;
        millisecondsDisplay?: DurationFormatDisplayOption | undefined;
        microseconds?: "long" | "short" | "narrow" | "numeric" | undefined;
        microsecondsDisplay?: DurationFormatDisplayOption | undefined;
        nanoseconds?: "long" | "short" | "narrow" | "numeric" | undefined;
        nanosecondsDisplay?: DurationFormatDisplayOption | undefined;
        fractionalDigits?: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | undefined;
    }

    /**
     * The Intl.DurationFormat object enables language-sensitive duration formatting.
     *
     * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat)
     */
    interface DurationFormat {
        /**
         * @param duration The duration object to be formatted. It should include some or all of the following properties: months, weeks, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/format).
         */
        format(duration: Partial<Record<DurationFormatUnit, number>>): string;
        /**
         * @param duration The duration object to be formatted. It should include some or all of the following properties: months, weeks, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/formatToParts).
         */
        formatToParts(duration: Partial<Record<DurationFormatUnit, number>>): DurationFormatPart[];
        /**
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/resolvedOptions).
         */
        resolvedOptions(): ResolvedDurationFormatOptions;
    }

    interface ResolvedDurationFormatOptions {
        locale: UnicodeBCP47LocaleIdentifier;
        numberingSystem: string;
        style: DurationFormatStyle;
        years: "long" | "short" | "narrow";
        yearsDisplay: DurationFormatDisplayOption;
        months: "long" | "short" | "narrow";
        monthsDisplay: DurationFormatDisplayOption;
        weeks: "long" | "short" | "narrow";
        weeksDisplay: DurationFormatDisplayOption;
        days: "long" | "short" | "narrow";
        daysDisplay: DurationFormatDisplayOption;
        hours: "long" | "short" | "narrow" | "numeric" | "2-digit";
        hoursDisplay: DurationFormatDisplayOption;
        minutes: "long" | "short" | "narrow" | "numeric" | "2-digit";
        minutesDisplay: DurationFormatDisplayOption;
        seconds: "long" | "short" | "narrow" | "numeric" | "2-digit";
        secondsDisplay: DurationFormatDisplayOption;
        milliseconds: "long" | "short" | "narrow" | "numeric";
        millisecondsDisplay: DurationFormatDisplayOption;
        microseconds: "long" | "short" | "narrow" | "numeric";
        microsecondsDisplay: DurationFormatDisplayOption;
        nanoseconds: "long" | "short" | "narrow" | "numeric";
        nanosecondsDisplay: DurationFormatDisplayOption;
        fractionalDigits?: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9;
    }

    const DurationFormat: {
        prototype: DurationFormat;

        /**
         * @param locales A string with a BCP 47 language tag, or an array of such strings.
         *   For the general form and interpretation of the `locales` argument, see the [Intl](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl#locale_identification_and_negotiation)
         *   page.
         *
         * @param options An object for setting up a duration format.
         *
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/DurationFormat).
         */
        new (locales?: LocalesArgument, options?: DurationFormatOptions): DurationFormat;

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
         * [MDN](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/DurationFormat/supportedLocalesOf).
         */
        supportedLocalesOf(locales?: LocalesArgument, options?: { localeMatcher?: DurationFormatLocaleMatcher; }): UnicodeBCP47LocaleIdentifier[];
    };
}

//========== lib.es2025.iterator.d.ts ==========
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

// NOTE: This is specified as what is essentially an unreachable module. All actual global declarations can be found
//       in the `declare global` section, below. This is necessary as there is currently no way to declare an `abstract`
//       member without declaring a `class`, but declaring `class Iterator<T>` globally would conflict with TypeScript's
//       general purpose `Iterator<T>` interface.

// Abstract type that allows us to mark `next` as `abstract`
declare abstract class __ztscIteratorAbstract<T, TResult = undefined, TNext = unknown> { // eslint-disable-line @typescript-eslint/no-unsafe-declaration-merging
    abstract next(value?: TNext): IteratorResult<T, TResult>;
}

// Merge all members of `IteratorObject<T>` into `Iterator<T>`
interface __ztscIteratorAbstract<T, TResult, TNext> extends IteratorObject<T, TResult, TNext> {}

// Capture the `Iterator` constructor in a type we can use in the `extends` clause of `IteratorConstructor`.
type IteratorObjectConstructor = typeof __ztscIteratorAbstract;

    // Global `IteratorObject<T, TReturn, TNext>` interface that can be augmented by polyfills
    interface IteratorObject<T, TReturn, TNext> {
        /**
         * Returns this iterator.
         */
        [Symbol.iterator](): IteratorObject<T, TReturn, TNext>;

        /**
         * Creates an iterator whose values are the result of applying the callback to the values from this iterator.
         * @param callbackfn A function that accepts up to two arguments to be used to transform values from the underlying iterator.
         */
        map<U>(callbackfn: (value: T, index: number) => U): IteratorObject<U, undefined, unknown>;

        /**
         * Creates an iterator whose values are those from this iterator for which the provided predicate returns true.
         * @param predicate A function that accepts up to two arguments to be used to test values from the underlying iterator.
         */
        filter<S extends T>(predicate: (value: T, index: number) => value is S): IteratorObject<S, undefined, unknown>;

        /**
         * Creates an iterator whose values are those from this iterator for which the provided predicate returns true.
         * @param predicate A function that accepts up to two arguments to be used to test values from the underlying iterator.
         */
        filter(predicate: (value: T, index: number) => unknown): IteratorObject<T, undefined, unknown>;

        /**
         * Creates an iterator whose values are the values from this iterator, stopping once the provided limit is reached.
         * @param limit The maximum number of values to yield.
         */
        take(limit: number): IteratorObject<T, undefined, unknown>;

        /**
         * Creates an iterator whose values are the values from this iterator after skipping the provided count.
         * @param count The number of values to drop.
         */
        drop(count: number): IteratorObject<T, undefined, unknown>;

        /**
         * Creates an iterator whose values are the result of applying the callback to the values from this iterator and then flattening the resulting iterators or iterables.
         * @param callback A function that accepts up to two arguments to be used to transform values from the underlying iterator into new iterators or iterables to be flattened into the result.
         */
        flatMap<U>(callback: (value: T, index: number) => Iterator<U, unknown, undefined> | Iterable<U, unknown, undefined>): IteratorObject<U, undefined, unknown>;

        /**
         * Calls the specified callback function for all the elements in this iterator. The return value of the callback function is the accumulated result, and is provided as an argument in the next call to the callback function.
         * @param callbackfn A function that accepts up to three arguments. The reduce method calls the callbackfn function one time for each element in the iterator.
         * @param initialValue If initialValue is specified, it is used as the initial value to start the accumulation. The first call to the callbackfn function provides this value as an argument instead of a value from the iterator.
         */
        reduce(callbackfn: (previousValue: T, currentValue: T, currentIndex: number) => T): T;
        reduce(callbackfn: (previousValue: T, currentValue: T, currentIndex: number) => T, initialValue: T): T;

        /**
         * Calls the specified callback function for all the elements in this iterator. The return value of the callback function is the accumulated result, and is provided as an argument in the next call to the callback function.
         * @param callbackfn A function that accepts up to three arguments. The reduce method calls the callbackfn function one time for each element in the iterator.
         * @param initialValue If initialValue is specified, it is used as the initial value to start the accumulation. The first call to the callbackfn function provides this value as an argument instead of a value from the iterator.
         */
        reduce<U>(callbackfn: (previousValue: U, currentValue: T, currentIndex: number) => U, initialValue: U): U;

        /**
         * Creates a new array from the values yielded by this iterator.
         */
        toArray(): T[];

        /**
         * Performs the specified action for each element in the iterator.
         * @param callbackfn A function that accepts up to two arguments. forEach calls the callbackfn function one time for each element in the iterator.
         */
        forEach(callbackfn: (value: T, index: number) => void): void;

        /**
         * Determines whether the specified callback function returns true for any element of this iterator.
         * @param predicate A function that accepts up to two arguments. The some method calls
         * the predicate function for each element in this iterator until the predicate returns a value
         * true, or until the end of the iterator.
         */
        some(predicate: (value: T, index: number) => unknown): boolean;

        /**
         * Determines whether all the members of this iterator satisfy the specified test.
         * @param predicate A function that accepts up to two arguments. The every method calls
         * the predicate function for each element in this iterator until the predicate returns
         * false, or until the end of this iterator.
         */
        every(predicate: (value: T, index: number) => unknown): boolean;

        /**
         * Returns the value of the first element in this iterator where predicate is true, and undefined
         * otherwise.
         * @param predicate find calls predicate once for each element of this iterator, in
         * order, until it finds one where predicate returns true. If such an element is found, find
         * immediately returns that element value. Otherwise, find returns undefined.
         */
        find<S extends T>(predicate: (value: T, index: number) => value is S): S | undefined;
        find(predicate: (value: T, index: number) => unknown): T | undefined;

        readonly [Symbol.toStringTag]: string;
    }

    // Global `IteratorConstructor` interface that can be augmented by polyfills
    interface IteratorConstructor extends IteratorObjectConstructor {
        /**
         * Creates a native iterator from an iterator or iterable object.
         * Returns its input if the input already inherits from the built-in Iterator class.
         * @param value An iterator or iterable object to convert a native iterator.
         */
        from<T>(value: Iterator<T, unknown, undefined> | Iterable<T, unknown, undefined>): IteratorObject<T, undefined, unknown>;
    }

    var Iterator: IteratorConstructor;

//========== lib.es2025.promise.d.ts ==========
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


interface PromiseConstructor {
    /**
     * Takes a callback of any kind (returns or throws, synchronously or asynchronously) and wraps its result
     * in a Promise.
     *
     * @param callbackFn A function that is called synchronously. It can do anything: either return
     * a value, throw an error, or return a promise.
     * @param args Additional arguments, that will be passed to the callback.
     *
     * @returns A Promise that is:
     * - Already fulfilled, if the callback synchronously returns a value.
     * - Already rejected, if the callback synchronously throws an error.
     * - Asynchronously fulfilled or rejected, if the callback returns a promise.
     */
    try<T, U extends unknown[]>(callbackFn: (...args: U) => T | PromiseLike<T>, ...args: U): Promise<Awaited<T>>;
}

//========== lib.es2025.regexp.d.ts ==========
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


interface RegExpConstructor {
    /**
     * Escapes any RegExp syntax characters in the input string, returning a
     * new string that can be safely interpolated into a RegExp as a literal
     * string to match.
     * @example
     * ```ts
     * const regExp = new RegExp(RegExp.escape("foo.bar"));
     * regExp.test("foo.bar"); // true
     * regExp.test("foo!bar"); // false
     * ```
     */
    escape(string: string): string;
}

//========== lib.es2025.d.ts ==========
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


/// <reference lib="es2024" />
/// <reference lib="es2025.collection" />
/// <reference lib="es2025.float16" />
/// <reference lib="es2025.intl" />
/// <reference lib="es2025.iterator" />
/// <reference lib="es2025.promise" />
/// <reference lib="es2025.regexp" />

//========== lib.esnext.temporal.d.ts ==========
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
/// <reference lib="es2020.intl" />
/// <reference lib="es2025.intl" />

declare namespace Temporal {
    type CalendarLike = PlainDate | PlainDateTime | PlainMonthDay | PlainYearMonth | ZonedDateTime | string;
    type DurationLike = Duration | DurationLikeObject | string;
    type InstantLike = Instant | ZonedDateTime | string;
    type PlainDateLike = PlainDate | ZonedDateTime | PlainDateTime | DateLikeObject | string;
    type PlainDateTimeLike = PlainDateTime | ZonedDateTime | PlainDate | DateTimeLikeObject | string;
    type PlainMonthDayLike = PlainMonthDay | DateLikeObject | string;
    type PlainTimeLike = PlainTime | PlainDateTime | ZonedDateTime | TimeLikeObject | string;
    type PlainYearMonthLike = PlainYearMonth | YearMonthLikeObject | string;
    type TimeZoneLike = ZonedDateTime | string;
    type ZonedDateTimeLike = ZonedDateTime | ZonedDateTimeLikeObject | string;

    type PartialTemporalLike<T extends object> = {
        [P in Exclude<keyof T, "calendar" | "timeZone">]?: T[P] | undefined;
    };

    interface DateLikeObject {
        year?: number | undefined;
        era?: string | undefined;
        eraYear?: number | undefined;
        month?: number | undefined;
        monthCode?: string | undefined;
        day: number;
        calendar?: string | undefined;
    }

    interface DateTimeLikeObject extends DateLikeObject, TimeLikeObject {}

    interface DurationLikeObject {
        years?: number | undefined;
        months?: number | undefined;
        weeks?: number | undefined;
        days?: number | undefined;
        hours?: number | undefined;
        minutes?: number | undefined;
        seconds?: number | undefined;
        milliseconds?: number | undefined;
        microseconds?: number | undefined;
        nanoseconds?: number | undefined;
    }

    interface TimeLikeObject {
        hour?: number | undefined;
        minute?: number | undefined;
        second?: number | undefined;
        millisecond?: number | undefined;
        microsecond?: number | undefined;
        nanosecond?: number | undefined;
    }

    interface YearMonthLikeObject extends Omit<DateLikeObject, "day"> {}

    interface ZonedDateTimeLikeObject extends DateTimeLikeObject {
        timeZone: TimeZoneLike;
        offset?: string | undefined;
    }

    type DateUnit = "year" | "month" | "week" | "day";
    type TimeUnit = "hour" | "minute" | "second" | "millisecond" | "microsecond" | "nanosecond";
    type PluralizeUnit<T extends DateUnit | TimeUnit> =
        | T
        | {
            year: "years";
            month: "months";
            week: "weeks";
            day: "days";
            hour: "hours";
            minute: "minutes";
            second: "seconds";
            millisecond: "milliseconds";
            microsecond: "microseconds";
            nanosecond: "nanoseconds";
        }[T];

    interface DisambiguationOptions {
        disambiguation?: "compatible" | "earlier" | "later" | "reject" | undefined;
    }

    interface OverflowOptions {
        overflow?: "constrain" | "reject" | undefined;
    }

    interface TransitionOptions {
        direction: "next" | "previous";
    }

    interface RoundingOptions<Units extends DateUnit | TimeUnit> {
        smallestUnit?: PluralizeUnit<Units> | undefined;
        roundingIncrement?: number | undefined;
        roundingMode?: "ceil" | "floor" | "expand" | "trunc" | "halfCeil" | "halfFloor" | "halfExpand" | "halfTrunc" | "halfEven" | undefined;
    }

    interface RoundingOptionsWithLargestUnit<Units extends DateUnit | TimeUnit> extends RoundingOptions<Units> {
        largestUnit?: "auto" | PluralizeUnit<Units> | undefined;
    }

    interface ToStringRoundingOptions<Units extends DateUnit | TimeUnit> extends Pick<RoundingOptions<Units>, "smallestUnit" | "roundingMode"> {}

    interface ToStringRoundingOptionsWithFractionalSeconds<Units extends DateUnit | TimeUnit> extends ToStringRoundingOptions<Units> {
        fractionalSecondDigits?: "auto" | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | undefined;
    }

    namespace Now {
        function timeZoneId(): string;
        function instant(): Instant;
        function plainDateTimeISO(timeZone?: TimeZoneLike): PlainDateTime;
        function zonedDateTimeISO(timeZone?: TimeZoneLike): ZonedDateTime;
        function plainDateISO(timeZone?: TimeZoneLike): PlainDate;
        function plainTimeISO(timeZone?: TimeZoneLike): PlainTime;
    }

    interface PlainDateToStringOptions {
        calendarName?: "auto" | "always" | "never" | "critical" | undefined;
    }

    interface PlainDateToZonedDateTimeOptions {
        plainTime?: PlainTimeLike | undefined;
        timeZone: TimeZoneLike;
    }

    interface PlainDate {
        readonly calendarId: string;
        readonly era: string | undefined;
        readonly eraYear: number | undefined;
        readonly year: number;
        readonly month: number;
        readonly monthCode: string;
        readonly day: number;
        readonly dayOfWeek: number;
        readonly dayOfYear: number;
        readonly weekOfYear: number | undefined;
        readonly yearOfWeek: number | undefined;
        readonly daysInWeek: number;
        readonly daysInMonth: number;
        readonly daysInYear: number;
        readonly monthsInYear: number;
        readonly inLeapYear: boolean;
        toPlainYearMonth(): PlainYearMonth;
        toPlainMonthDay(): PlainMonthDay;
        add(duration: DurationLike, options?: OverflowOptions): PlainDate;
        subtract(duration: DurationLike, options?: OverflowOptions): PlainDate;
        with(dateLike: PartialTemporalLike<DateLikeObject>, options?: OverflowOptions): PlainDate;
        withCalendar(calendarLike: CalendarLike): PlainDate;
        until(other: PlainDateLike, options?: RoundingOptionsWithLargestUnit<DateUnit>): Duration;
        since(other: PlainDateLike, options?: RoundingOptionsWithLargestUnit<DateUnit>): Duration;
        equals(other: PlainDateLike): boolean;
        toPlainDateTime(time?: PlainTimeLike): PlainDateTime;
        toZonedDateTime(timeZone: TimeZoneLike): ZonedDateTime;
        toZonedDateTime(item: PlainDateToZonedDateTimeOptions): ZonedDateTime;
        toString(options?: PlainDateToStringOptions): string;
        toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;
        toJSON(): string;
        valueOf(): never;
        readonly [Symbol.toStringTag]: "Temporal.PlainDate";
    }

    interface PlainDateConstructor {
        new (isoYear: number, isoMonth: number, isoDay: number, calendar?: string): PlainDate;
        readonly prototype: PlainDate;
        from(item: PlainDateLike, options?: OverflowOptions): PlainDate;
        compare(one: PlainDateLike, two: PlainDateLike): number;
    }
    var PlainDate: PlainDateConstructor;

    interface PlainTimeToStringOptions extends ToStringRoundingOptionsWithFractionalSeconds<Exclude<TimeUnit, "hour">> {}

    interface PlainTime {
        readonly hour: number;
        readonly minute: number;
        readonly second: number;
        readonly millisecond: number;
        readonly microsecond: number;
        readonly nanosecond: number;
        add(duration: DurationLike): PlainTime;
        subtract(duration: DurationLike): PlainTime;
        with(timeLike: PartialTemporalLike<TimeLikeObject>, options?: OverflowOptions): PlainTime;
        until(other: PlainTimeLike, options?: RoundingOptionsWithLargestUnit<TimeUnit>): Duration;
        since(other: PlainTimeLike, options?: RoundingOptionsWithLargestUnit<TimeUnit>): Duration;
        equals(other: PlainTimeLike): boolean;
        round(roundTo: PluralizeUnit<TimeUnit>): PlainTime;
        round(roundTo: RoundingOptions<TimeUnit>): PlainTime;
        toString(options?: PlainTimeToStringOptions): string;
        toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;
        toJSON(): string;
        valueOf(): never;
        readonly [Symbol.toStringTag]: "Temporal.PlainTime";
    }

    interface PlainTimeConstructor {
        new (hour?: number, minute?: number, second?: number, millisecond?: number, microsecond?: number, nanosecond?: number): PlainTime;
        readonly prototype: PlainTime;
        from(item: PlainTimeLike, options?: OverflowOptions): PlainTime;
        compare(one: PlainTimeLike, two: PlainTimeLike): number;
    }
    var PlainTime: PlainTimeConstructor;

    interface PlainDateTimeToStringOptions extends PlainDateToStringOptions, PlainTimeToStringOptions {}

    interface PlainDateTime {
        readonly calendarId: string;
        readonly era: string | undefined;
        readonly eraYear: number | undefined;
        readonly year: number;
        readonly month: number;
        readonly monthCode: string;
        readonly day: number;
        readonly hour: number;
        readonly minute: number;
        readonly second: number;
        readonly millisecond: number;
        readonly microsecond: number;
        readonly nanosecond: number;
        readonly dayOfWeek: number;
        readonly dayOfYear: number;
        readonly weekOfYear: number | undefined;
        readonly yearOfWeek: number | undefined;
        readonly daysInWeek: number;
        readonly daysInMonth: number;
        readonly daysInYear: number;
        readonly monthsInYear: number;
        readonly inLeapYear: boolean;
        with(dateTimeLike: PartialTemporalLike<DateTimeLikeObject>, options?: OverflowOptions): PlainDateTime;
        withPlainTime(plainTime?: PlainTimeLike): PlainDateTime;
        withCalendar(calendar: CalendarLike): PlainDateTime;
        add(duration: DurationLike, options?: OverflowOptions): PlainDateTime;
        subtract(duration: DurationLike, options?: OverflowOptions): PlainDateTime;
        until(other: PlainDateTimeLike, options?: RoundingOptionsWithLargestUnit<DateUnit | TimeUnit>): Duration;
        since(other: PlainDateTimeLike, options?: RoundingOptionsWithLargestUnit<DateUnit | TimeUnit>): Duration;
        round(roundTo: PluralizeUnit<"day" | TimeUnit>): PlainDateTime;
        round(roundTo: RoundingOptions<"day" | TimeUnit>): PlainDateTime;
        equals(other: PlainDateTimeLike): boolean;
        toString(options?: PlainDateTimeToStringOptions): string;
        toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;
        toJSON(): string;
        valueOf(): never;
        toZonedDateTime(timeZone: TimeZoneLike, options?: DisambiguationOptions): ZonedDateTime;
        toPlainDate(): PlainDate;
        toPlainTime(): PlainTime;
        readonly [Symbol.toStringTag]: "Temporal.PlainDateTime";
    }

    interface PlainDateTimeConstructor {
        new (isoYear: number, isoMonth: number, isoDay: number, hour?: number, minute?: number, second?: number, millisecond?: number, microsecond?: number, nanosecond?: number, calendar?: string): PlainDateTime;
        readonly prototype: PlainDateTime;
        from(item: PlainDateTimeLike, options?: OverflowOptions): PlainDateTime;
        compare(one: PlainDateTimeLike, two: PlainDateTimeLike): number;
    }
    var PlainDateTime: PlainDateTimeConstructor;

    interface ZonedDateTimeToStringOptions extends PlainDateTimeToStringOptions {
        offset?: "auto" | "never" | undefined;
        timeZoneName?: "auto" | "never" | "critical" | undefined;
    }

    interface ZonedDateTimeFromOptions extends OverflowOptions, DisambiguationOptions {
        offset?: "use" | "ignore" | "prefer" | "reject" | undefined;
    }

    interface ZonedDateTime {
        readonly calendarId: string;
        readonly timeZoneId: string;
        readonly era: string | undefined;
        readonly eraYear: number | undefined;
        readonly year: number;
        readonly month: number;
        readonly monthCode: string;
        readonly day: number;
        readonly hour: number;
        readonly minute: number;
        readonly second: number;
        readonly millisecond: number;
        readonly microsecond: number;
        readonly nanosecond: number;
        readonly epochMilliseconds: number;
        readonly epochNanoseconds: bigint;
        readonly dayOfWeek: number;
        readonly dayOfYear: number;
        readonly weekOfYear: number | undefined;
        readonly yearOfWeek: number | undefined;
        readonly hoursInDay: number;
        readonly daysInWeek: number;
        readonly daysInMonth: number;
        readonly daysInYear: number;
        readonly monthsInYear: number;
        readonly inLeapYear: boolean;
        readonly offsetNanoseconds: number;
        readonly offset: string;
        with(zonedDateTimeLike: PartialTemporalLike<ZonedDateTimeLikeObject>, options?: ZonedDateTimeFromOptions): ZonedDateTime;
        withPlainTime(plainTime?: PlainTimeLike): ZonedDateTime;
        withTimeZone(timeZone: TimeZoneLike): ZonedDateTime;
        withCalendar(calendar: CalendarLike): ZonedDateTime;
        add(duration: DurationLike, options?: OverflowOptions): ZonedDateTime;
        subtract(duration: DurationLike, options?: OverflowOptions): ZonedDateTime;
        until(other: ZonedDateTimeLike, options?: RoundingOptionsWithLargestUnit<DateUnit | TimeUnit>): Duration;
        since(other: ZonedDateTimeLike, options?: RoundingOptionsWithLargestUnit<DateUnit | TimeUnit>): Duration;
        round(roundTo: PluralizeUnit<"day" | TimeUnit>): ZonedDateTime;
        round(roundTo: RoundingOptions<"day" | TimeUnit>): ZonedDateTime;
        equals(other: ZonedDateTimeLike): boolean;
        toString(options?: ZonedDateTimeToStringOptions): string;
        toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;
        toJSON(): string;
        valueOf(): never;
        startOfDay(): ZonedDateTime;
        getTimeZoneTransition(direction: "next" | "previous"): ZonedDateTime | null;
        getTimeZoneTransition(direction: TransitionOptions): ZonedDateTime | null;
        toInstant(): Instant;
        toPlainDate(): PlainDate;
        toPlainTime(): PlainTime;
        toPlainDateTime(): PlainDateTime;
        readonly [Symbol.toStringTag]: "Temporal.ZonedDateTime";
    }

    interface ZonedDateTimeConstructor {
        new (epochNanoseconds: bigint, timeZone: string, calendar?: string): ZonedDateTime;
        readonly prototype: ZonedDateTime;
        from(item: ZonedDateTimeLike, options?: ZonedDateTimeFromOptions): ZonedDateTime;
        compare(one: ZonedDateTimeLike, two: ZonedDateTimeLike): number;
    }
    var ZonedDateTime: ZonedDateTimeConstructor;

    interface DurationRelativeToOptions {
        relativeTo?: ZonedDateTimeLike | PlainDateLike | undefined;
    }

    interface DurationRoundingOptions extends DurationRelativeToOptions, RoundingOptionsWithLargestUnit<DateUnit | TimeUnit> {}

    interface DurationToStringOptions extends ToStringRoundingOptionsWithFractionalSeconds<Exclude<TimeUnit, "hour" | "minute">> {}

    interface DurationTotalOptions extends DurationRelativeToOptions {
        unit: PluralizeUnit<DateUnit | TimeUnit>;
    }

    interface Duration {
        readonly years: number;
        readonly months: number;
        readonly weeks: number;
        readonly days: number;
        readonly hours: number;
        readonly minutes: number;
        readonly seconds: number;
        readonly milliseconds: number;
        readonly microseconds: number;
        readonly nanoseconds: number;
        readonly sign: number;
        readonly blank: boolean;
        with(durationLike: PartialTemporalLike<DurationLikeObject>): Duration;
        negated(): Duration;
        abs(): Duration;
        add(other: DurationLike): Duration;
        subtract(other: DurationLike): Duration;
        round(roundTo: PluralizeUnit<"day" | TimeUnit>): Duration;
        round(roundTo: DurationRoundingOptions): Duration;
        total(totalOf: PluralizeUnit<"day" | TimeUnit>): number;
        total(totalOf: DurationTotalOptions): number;
        toString(options?: DurationToStringOptions): string;
        toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DurationFormatOptions): string;
        toJSON(): string;
        valueOf(): never;
        readonly [Symbol.toStringTag]: "Temporal.Duration";
    }

    interface DurationConstructor {
        new (years?: number, months?: number, weeks?: number, days?: number, hours?: number, minutes?: number, seconds?: number, milliseconds?: number, microseconds?: number, nanoseconds?: number): Duration;
        readonly prototype: Duration;
        from(item: DurationLike): Duration;
        compare(one: DurationLike, two: DurationLike, options?: DurationRelativeToOptions): number;
    }
    var Duration: DurationConstructor;

    interface InstantToStringOptions extends PlainTimeToStringOptions {
        timeZone?: TimeZoneLike | undefined;
    }

    interface Instant {
        readonly epochMilliseconds: number;
        readonly epochNanoseconds: bigint;
        add(duration: DurationLike): Instant;
        subtract(duration: DurationLike): Instant;
        until(other: InstantLike, options?: RoundingOptionsWithLargestUnit<TimeUnit>): Duration;
        since(other: InstantLike, options?: RoundingOptionsWithLargestUnit<TimeUnit>): Duration;
        round(roundTo: PluralizeUnit<TimeUnit>): Instant;
        round(roundTo: RoundingOptions<TimeUnit>): Instant;
        equals(other: InstantLike): boolean;
        toString(options?: InstantToStringOptions): string;
        toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;
        toJSON(): string;
        valueOf(): never;
        toZonedDateTimeISO(timeZone: TimeZoneLike): ZonedDateTime;
        readonly [Symbol.toStringTag]: "Temporal.Instant";
    }

    interface InstantConstructor {
        new (epochNanoseconds: bigint): Instant;
        readonly prototype: Instant;
        from(item: InstantLike): Instant;
        fromEpochMilliseconds(epochMilliseconds: number): Instant;
        fromEpochNanoseconds(epochNanoseconds: bigint): Instant;
        compare(one: InstantLike, two: InstantLike): number;
    }
    var Instant: InstantConstructor;

    interface PlainYearMonthToPlainDateOptions {
        day: number;
    }

    interface PlainYearMonth {
        readonly calendarId: string;
        readonly era: string | undefined;
        readonly eraYear: number | undefined;
        readonly year: number;
        readonly month: number;
        readonly monthCode: string;
        readonly daysInYear: number;
        readonly daysInMonth: number;
        readonly monthsInYear: number;
        readonly inLeapYear: boolean;
        with(yearMonthLike: PartialTemporalLike<YearMonthLikeObject>, options?: OverflowOptions): PlainYearMonth;
        add(duration: DurationLike, options?: OverflowOptions): PlainYearMonth;
        subtract(duration: DurationLike, options?: OverflowOptions): PlainYearMonth;
        until(other: PlainYearMonthLike, options?: RoundingOptionsWithLargestUnit<"year" | "month">): Duration;
        since(other: PlainYearMonthLike, options?: RoundingOptionsWithLargestUnit<"year" | "month">): Duration;
        equals(other: PlainYearMonthLike): boolean;
        toString(options?: PlainDateToStringOptions): string;
        toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;
        toJSON(): string;
        valueOf(): never;
        toPlainDate(item: PlainYearMonthToPlainDateOptions): PlainDate;
        readonly [Symbol.toStringTag]: "Temporal.PlainYearMonth";
    }

    interface PlainYearMonthConstructor {
        new (isoYear: number, isoMonth: number, calendar?: string, referenceISODay?: number): PlainYearMonth;
        readonly prototype: PlainYearMonth;
        from(item: PlainYearMonthLike, options?: OverflowOptions): PlainYearMonth;
        compare(one: PlainYearMonthLike, two: PlainYearMonthLike): number;
    }
    var PlainYearMonth: PlainYearMonthConstructor;

    interface PlainMonthDayToPlainDateOptions {
        era?: string | undefined;
        eraYear?: number | undefined;
        year?: number | undefined;
    }

    interface PlainMonthDay {
        readonly calendarId: string;
        readonly monthCode: string;
        readonly day: number;
        with(monthDayLike: PartialTemporalLike<DateLikeObject>, options?: OverflowOptions): PlainMonthDay;
        equals(other: PlainMonthDayLike): boolean;
        toString(options?: PlainDateToStringOptions): string;
        toLocaleString(locales?: Intl.LocalesArgument, options?: Intl.DateTimeFormatOptions): string;
        toJSON(): string;
        valueOf(): never;
        toPlainDate(item: PlainMonthDayToPlainDateOptions): PlainDate;
        readonly [Symbol.toStringTag]: "Temporal.PlainMonthDay";
    }

    interface PlainMonthDayConstructor {
        new (isoMonth: number, isoDay: number, calendar?: string, referenceISOYear?: number): PlainMonthDay;
        readonly prototype: PlainMonthDay;
        from(item: PlainMonthDayLike, options?: OverflowOptions): PlainMonthDay;
    }
    var PlainMonthDay: PlainMonthDayConstructor;
}

//========== lib.esnext.intl.d.ts ==========
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


/// <reference lib="esnext.temporal" />

declare namespace Intl {
    type FormattableTemporalObject = Temporal.PlainDate | Temporal.PlainYearMonth | Temporal.PlainMonthDay | Temporal.PlainTime | Temporal.PlainDateTime | Temporal.Instant;

    interface DateTimeFormat {
        format(date?: FormattableTemporalObject | Date | number): string;
        formatToParts(date?: FormattableTemporalObject | Date | number): DateTimeFormatPart[];
        formatRange(startDate: FormattableTemporalObject | Date | number, endDate: FormattableTemporalObject | Date | number): string;
        formatRangeToParts(startDate: FormattableTemporalObject | Date | number, endDate: FormattableTemporalObject | Date | number): DateTimeRangeFormatPart[];
    }

    interface Locale {
        /**
         * Returns a list of one or more unique calendar identifiers for this locale.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getCalendars)
         */
        getCalendars(): string[];
        /**
         * Returns a list of one or more collation types for this locale.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getCollations)
         */
        getCollations(): string[];
        /**
         * Returns a list of one or more unique hour cycle identifiers for this locale.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getHourCycles)
         */
        getHourCycles(): string[];
        /**
         * Returns a list of one or more unique numbering system identifiers for this locale.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getNumberingSystems)
         */
        getNumberingSystems(): string[];
        /**
         * Returns the ordering of characters indicated by either ltr (left-to-right) or by rtl (right-to-left) for this locale.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getTextInfo)
         */
        getTextInfo(): TextInfo;
        /**
         * Returns a list of supported time zones for this locale.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getTimeZones)
         */
        getTimeZones(): string[] | undefined;
        /**
         * Returns a `WeekInfo` object with the properties `firstDay`, `weekend` and `minimalDays` for this locale.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getWeekInfo)
         */
        getWeekInfo(): WeekInfo;
    }

    /**
     * An object representing text typesetting information associated with the Locale data specified in UTS 35's Layouts Elements.
     *
     * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getTextInfo#return_value)
     */
    interface TextInfo {
        /**
         * A string indicating the direction of text for the locale. Can be either "ltr" (left-to-right) or "rtl" (right-to-left).
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getTextInfo#direction)
         */
        direction?: "ltr" | "rtl";
    }

    /**
     * An object representing week information associated with the Locale data specified in UTS 35's Week Elements.
     *
     * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getWeekInfo#return_value)
     */
    interface WeekInfo {
        /**
         * An integer between 1 (Monday) and 7 (Sunday) indicating the first day of the week for the locale. Commonly 1, 5, 6, or 7.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getWeekInfo#firstday)
         */
        firstDay: number;
        /**
         * An array of integers between 1 and 7 indicating the weekend days for the locale.
         *
         * [MDN Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale/getWeekInfo#weekend)
         */
        weekend: number[];
    }
}

//========== lib.esnext.collection.d.ts ==========
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


/// <reference lib="es2025.collection" />

interface Map<K, V> {
    /**
     * Returns a specified element from the Map object.
     * If no element is associated with the specified key, a new element with the value `defaultValue` will be inserted into the Map and returned.
     * @returns The element associated with the specified key, which will be `defaultValue` if no element previously existed.
     */
    getOrInsert(key: K, defaultValue: V): V;
    /**
     * Returns a specified element from the Map object.
     * If no element is associated with the specified key, the result of passing the specified key to the `callback` function will be inserted into the Map and returned.
     * @returns The element associated with the specific key, which will be the newly computed value if no element previously existed.
     */
    getOrInsertComputed(key: K, callback: (key: K) => V): V;
}

interface WeakMap<K extends WeakKey, V> {
    /**
     * Returns a specified element from the WeakMap object.
     * If no element is associated with the specified key, a new element with the value `defaultValue` will be inserted into the WeakMap and returned.
     * @returns The element associated with the specified key, which will be `defaultValue` if no element previously existed.
     */
    getOrInsert(key: K, defaultValue: V): V;
    /**
     * Returns a specified element from the WeakMap object.
     * If no element is associated with the specified key, the result of passing the specified key to the `callback` function will be inserted into the WeakMap and returned.
     * @returns The element associated with the specific key, which will be the newly computed value if no element previously existed.
     */
    getOrInsertComputed(key: K, callback: (key: K) => V): V;
}

//========== lib.esnext.decorators.d.ts ==========
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
/// <reference lib="decorators" />

interface SymbolConstructor {
    readonly metadata: unique symbol;
}

interface Function {
    [Symbol.metadata]: DecoratorMetadata | null;
}

//========== lib.esnext.disposable.d.ts ==========
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
/// <reference lib="es2018.asynciterable" />

interface SymbolConstructor {
    /**
     * A method that is used to release resources held by an object. Called by the semantics of the `using` statement.
     */
    readonly dispose: unique symbol;

    /**
     * A method that is used to asynchronously release resources held by an object. Called by the semantics of the `await using` statement.
     */
    readonly asyncDispose: unique symbol;
}

interface Disposable {
    [Symbol.dispose](): void;
}

interface AsyncDisposable {
    [Symbol.asyncDispose](): PromiseLike<void>;
}

interface SuppressedError extends Error {
    error: any;
    suppressed: any;
}

interface SuppressedErrorConstructor {
    new (error: any, suppressed: any, message?: string): SuppressedError;
    (error: any, suppressed: any, message?: string): SuppressedError;
    readonly prototype: SuppressedError;
}
declare var SuppressedError: SuppressedErrorConstructor;

interface DisposableStack {
    /**
     * Returns a value indicating whether this stack has been disposed.
     */
    readonly disposed: boolean;
    /**
     * Disposes each resource in the stack in the reverse order that they were added.
     */
    dispose(): void;
    /**
     * Adds a disposable resource to the stack, returning the resource.
     * @param value The resource to add. `null` and `undefined` will not be added, but will be returned.
     * @returns The provided {@link value}.
     */
    use<T extends Disposable | null | undefined>(value: T): T;
    /**
     * Adds a value and associated disposal callback as a resource to the stack.
     * @param value The value to add.
     * @param onDispose The callback to use in place of a `[Symbol.dispose]()` method. Will be invoked with `value`
     * as the first parameter.
     * @returns The provided {@link value}.
     */
    adopt<T>(value: T, onDispose: (value: T) => void): T;
    /**
     * Adds a callback to be invoked when the stack is disposed.
     */
    defer(onDispose: () => void): void;
    /**
     * Move all resources out of this stack and into a new `DisposableStack`, and marks this stack as disposed.
     * @example
     * ```ts
     * class C {
     *   #res1: Disposable;
     *   #res2: Disposable;
     *   #disposables: DisposableStack;
     *   constructor() {
     *     // stack will be disposed when exiting constructor for any reason
     *     using stack = new DisposableStack();
     *
     *     // get first resource
     *     this.#res1 = stack.use(getResource1());
     *
     *     // get second resource. If this fails, both `stack` and `#res1` will be disposed.
     *     this.#res2 = stack.use(getResource2());
     *
     *     // all operations succeeded, move resources out of `stack` so that they aren't disposed
     *     // when constructor exits
     *     this.#disposables = stack.move();
     *   }
     *
     *   [Symbol.dispose]() {
     *     this.#disposables.dispose();
     *   }
     * }
     * ```
     */
    move(): DisposableStack;
    [Symbol.dispose](): void;
    readonly [Symbol.toStringTag]: string;
}

interface DisposableStackConstructor {
    new (): DisposableStack;
    readonly prototype: DisposableStack;
}
declare var DisposableStack: DisposableStackConstructor;

interface AsyncDisposableStack {
    /**
     * Returns a value indicating whether this stack has been disposed.
     */
    readonly disposed: boolean;
    /**
     * Disposes each resource in the stack in the reverse order that they were added.
     */
    disposeAsync(): Promise<void>;
    /**
     * Adds a disposable resource to the stack, returning the resource.
     * @param value The resource to add. `null` and `undefined` will not be added, but will be returned.
     * @returns The provided {@link value}.
     */
    use<T extends AsyncDisposable | Disposable | null | undefined>(value: T): T;
    /**
     * Adds a value and associated disposal callback as a resource to the stack.
     * @param value The value to add.
     * @param onDisposeAsync The callback to use in place of a `[Symbol.asyncDispose]()` method. Will be invoked with `value`
     * as the first parameter.
     * @returns The provided {@link value}.
     */
    adopt<T>(value: T, onDisposeAsync: (value: T) => PromiseLike<void> | void): T;
    /**
     * Adds a callback to be invoked when the stack is disposed.
     */
    defer(onDisposeAsync: () => PromiseLike<void> | void): void;
    /**
     * Move all resources out of this stack and into a new `DisposableStack`, and marks this stack as disposed.
     * @example
     * ```ts
     * class C {
     *   #res1: Disposable;
     *   #res2: Disposable;
     *   #disposables: DisposableStack;
     *   constructor() {
     *     // stack will be disposed when exiting constructor for any reason
     *     using stack = new DisposableStack();
     *
     *     // get first resource
     *     this.#res1 = stack.use(getResource1());
     *
     *     // get second resource. If this fails, both `stack` and `#res1` will be disposed.
     *     this.#res2 = stack.use(getResource2());
     *
     *     // all operations succeeded, move resources out of `stack` so that they aren't disposed
     *     // when constructor exits
     *     this.#disposables = stack.move();
     *   }
     *
     *   [Symbol.dispose]() {
     *     this.#disposables.dispose();
     *   }
     * }
     * ```
     */
    move(): AsyncDisposableStack;
    [Symbol.asyncDispose](): Promise<void>;
    readonly [Symbol.toStringTag]: string;
}

interface AsyncDisposableStackConstructor {
    new (): AsyncDisposableStack;
    readonly prototype: AsyncDisposableStack;
}
declare var AsyncDisposableStack: AsyncDisposableStackConstructor;

interface IteratorObject<T, TReturn, TNext> extends Disposable {
}

interface AsyncIteratorObject<T, TReturn, TNext> extends AsyncDisposable {
}

//========== lib.esnext.array.d.ts ==========
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


interface ArrayConstructor {
    /**
     * Creates an array from an async iterator or iterable object.
     * @param iterableOrArrayLike An async iterator or array-like object to convert to an array.
     */
    fromAsync<T>(iterableOrArrayLike: AsyncIterable<T> | Iterable<T | PromiseLike<T>> | ArrayLike<T | PromiseLike<T>>): Promise<T[]>;

    /**
     * Creates an array from an async iterator or iterable object.
     *
     * @param iterableOrArrayLike An async iterator or array-like object to convert to an array.
     * @param mapfn A mapping function to call on every element of itarableOrArrayLike.
     *      Each return value is awaited before being added to result array.
     * @param thisArg Value of 'this' used when executing mapfn.
     */
    fromAsync<T, U>(iterableOrArrayLike: AsyncIterable<T> | Iterable<T> | ArrayLike<T>, mapFn: (value: Awaited<T>, index: number) => U, thisArg?: any): Promise<Awaited<U>[]>;
}

//========== lib.esnext.error.d.ts ==========
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


interface ErrorConstructor {
    /**
     * Indicates whether the argument provided is a built-in Error instance or not.
     */
    isError(error: unknown): error is Error;
}

//========== lib.esnext.sharedmemory.d.ts ==========
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


interface Atomics {
    /**
     * Performs a finite-time microwait by signaling to the operating system or
     * CPU that the current executing code is in a spin-wait loop.
     */
    pause(n?: number): void;
}

//========== lib.esnext.typedarrays.d.ts ==========
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


interface Uint8Array<TArrayBuffer extends ArrayBufferLike> {
    /**
     * Converts the `Uint8Array` to a base64-encoded string.
     * @param options If provided, sets the alphabet and padding behavior used.
     * @returns A base64-encoded string.
     */
    toBase64(
        options?: {
            alphabet?: "base64" | "base64url" | undefined;
            omitPadding?: boolean | undefined;
        },
    ): string;

    /**
     * Sets the `Uint8Array` from a base64-encoded string.
     * @param string The base64-encoded string.
     * @param options If provided, specifies the alphabet and handling of the last chunk.
     * @returns An object containing the number of bytes read and written.
     * @throws {SyntaxError} If the input string contains characters outside the specified alphabet, or if the last
     * chunk is inconsistent with the `lastChunkHandling` option.
     */
    setFromBase64(
        string: string,
        options?: {
            alphabet?: "base64" | "base64url" | undefined;
            lastChunkHandling?: "loose" | "strict" | "stop-before-partial" | undefined;
        },
    ): {
        read: number;
        written: number;
    };

    /**
     * Converts the `Uint8Array` to a base16-encoded string.
     * @returns A base16-encoded string.
     */
    toHex(): string;

    /**
     * Sets the `Uint8Array` from a base16-encoded string.
     * @param string The base16-encoded string.
     * @returns An object containing the number of bytes read and written.
     */
    setFromHex(string: string): {
        read: number;
        written: number;
    };
}

interface Uint8ArrayConstructor {
    /**
     * Creates a new `Uint8Array` from a base64-encoded string.
     * @param string The base64-encoded string.
     * @param options If provided, specifies the alphabet and handling of the last chunk.
     * @returns A new `Uint8Array` instance.
     * @throws {SyntaxError} If the input string contains characters outside the specified alphabet, or if the last
     * chunk is inconsistent with the `lastChunkHandling` option.
     */
    fromBase64(
        string: string,
        options?: {
            alphabet?: "base64" | "base64url" | undefined;
            lastChunkHandling?: "loose" | "strict" | "stop-before-partial" | undefined;
        },
    ): Uint8Array<ArrayBuffer>;

    /**
     * Creates a new `Uint8Array` from a base16-encoded string.
     * @returns A new `Uint8Array` instance.
     */
    fromHex(
        string: string,
    ): Uint8Array<ArrayBuffer>;
}

//========== lib.esnext.date.d.ts ==========
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


/// <reference lib="esnext.temporal" />

interface Date {
    toTemporalInstant(): Temporal.Instant;
}

//========== lib.esnext.d.ts ==========
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


/// <reference lib="es2025" />
/// <reference lib="esnext.intl" />
/// <reference lib="esnext.collection" />
/// <reference lib="esnext.decorators" />
/// <reference lib="esnext.disposable" />
/// <reference lib="esnext.array" />
/// <reference lib="esnext.error" />
/// <reference lib="esnext.sharedmemory" />
/// <reference lib="esnext.typedarrays" />
/// <reference lib="esnext.temporal" />
/// <reference lib="esnext.date" />
