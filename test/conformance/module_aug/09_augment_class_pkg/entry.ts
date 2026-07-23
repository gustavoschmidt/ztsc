import { Widget } from "mylib";
import "mylib-plugin";
declare const w: Widget;
const a: string = w.core;
const g: string = w.greet();
const b: number = w.extra;
const bad: string = w.extra;
w.absentXyz;
