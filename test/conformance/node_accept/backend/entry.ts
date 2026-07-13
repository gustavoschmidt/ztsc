/// <reference types="node" />
import "./express";
import "./app-augment";
import { readFileSync, existsSync, sep } from "fs";
import { setTimeout } from "timers";

// `process` global; its Process interface is merged across globals.d.ts
// (pid) and process.d.ts (env, cwd).
const pid: number = process.pid;
const cwd: string = process.cwd();

// ProcessEnv merged across process.d.ts (index signature) and
// app-augment.d.ts (NODE_ENV). Declared prop wins over the index signature.
const nodeEnv: string = process.env.NODE_ENV;
const home: string | undefined = process.env.HOME;

// fs ambient module; readFileSync overload picks Buffer vs string.
const buf: Buffer = readFileSync("/etc/hostname");
const text: string = readFileSync("/etc/hostname", "utf8");
const exists: boolean = existsSync("/tmp");
const s: string = sep;

// Buffer value+type global merge.
const b2: Buffer = Buffer.from("hello");
const n: number = b2.length;
const isB: boolean = Buffer.isBuffer(b2);

// Timer return type is NodeJS.Timeout, whose interface lives in timers.d.ts
// under the same NodeJS namespace reopened by globals/process.
const t: NodeJS.Timeout = setTimeout(() => {}, 1000);
const again: NodeJS.Timeout = t.refresh();

// Express.Request merged: path (base) + user (app augmentation).
function handle(req: Express.Request): string {
  const u: string = req.user === undefined ? "anon" : req.user;
  return req.path + u;
}

// --- intentional type errors, expected to match tsc ---
const badPid: string = process.pid; // number -> string
const badBuf: string = readFileSync("/x"); // Buffer -> string
const badEnv: number = process.env.NODE_ENV; // string -> number
const missing: string = process.missing; // no 'missing' on Process
