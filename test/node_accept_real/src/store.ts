/// <reference types="node" />
import { readFileSync, existsSync, writeFileSync } from "fs";
import { join } from "path";

// A tiny file-backed blob store over real `fs` + the global `Buffer`.
export class FileStore {
  private dir: string;
  constructor(dir: string) {
    this.dir = dir;
  }
  read(name: string): Buffer {
    return readFileSync(join(this.dir, name));
  }
  has(name: string): boolean {
    return existsSync(join(this.dir, name));
  }
  write(name: string, body: Buffer): void {
    writeFileSync(join(this.dir, name), body);
  }
  size(name: string): number {
    return this.read(name).length;
  }
}
