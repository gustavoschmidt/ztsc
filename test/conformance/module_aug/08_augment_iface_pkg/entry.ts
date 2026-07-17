import { Base } from "mylib";
import "mylib-plugin";
declare const x: Base;
const a: string = x.core;
const b: number = x.extra;
const bad: string = x.extra;
