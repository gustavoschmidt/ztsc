/// <reference types="node" />
import { loadConfig, Config } from "./config";
import { FileStore } from "./store";
import { EventEmitter } from "events";
import { setTimeout } from "timers";

const cfg: Config = loadConfig();
const store = new FileStore(process.cwd());
const bus: EventEmitter = new EventEmitter();

const pid: number = process.pid;
const argv: string[] = process.argv;
const banner: Buffer = Buffer.from("ztsc backend " + cfg.env);
const timer: NodeJS.Timeout = setTimeout(() => bus.emit("tick"), cfg.port);

if (store.has("seed.bin")) {
  const n: number = store.size("seed.bin");
}

// --- planted type mistakes; must match tsc 5.5.4 exactly ---
const badPid: string = process.pid;              // number -> string
const badHost: number = cfg.host;                // string -> number (cross-file Config)
const badEnv: number = process.env.NODE_ENV;     // string|undefined -> number (Dict index sig)
const badData: string = store.read("x");         // Buffer -> string
const badMissing: number = process.doesNotExist; // no 'doesNotExist' on Process
