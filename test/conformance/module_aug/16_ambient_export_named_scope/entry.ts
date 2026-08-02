/// <reference path="./ambient.d.ts" />
import { Session, open, Note } from "insp";
import { promises } from "fsish";
import { test } from "testish";

declare const s: Session;
declare const n: Note;
s.connect();
open(1);
const m: string = n.method;
const f: string = promises.readFile("x");
test();
const bad: number = n.method;
const bad2: number = promises.readFile("x");
