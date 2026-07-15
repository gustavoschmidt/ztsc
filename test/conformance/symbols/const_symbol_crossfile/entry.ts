import { Table } from "./table";
import { entityKind, other, DrizzleEntity } from "./entity";

// The imported `entityKind` names the SAME key declared in table.ts.
const a: string = Table[entityKind];
const bad: number = Table[entityKind]; // string -> number

// A different imported unique symbol must not resolve.
const miss = Table[other]; // TS7053

// Structural: an object literal with the imported key satisfies the interface.
const e: DrizzleEntity = { [entityKind]: "x" };
const eBad: DrizzleEntity = {}; // missing '[entityKind]'
