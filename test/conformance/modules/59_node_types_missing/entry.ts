// No @types/node anywhere: tsc blames the missing node typings by name
// (TS2591) for its own core modules and globals, and falls back to the
// generic TS2307/TS2304 for everything else.
import type { WriteStream } from "node:tty";
import type { Stats } from "fs";
import type { Chunk } from "stream/consumers";
import type { Missing } from "node:nosuch";
import type { Other } from "nosuchpkg";

export type Bundle = [WriteStream, Stats, Chunk, Missing, Other];

export declare function readIt(b: Buffer): void;
export declare function writeIt(): Buffer;

export const pid = process;
export const gone = totallyUnknownName;
