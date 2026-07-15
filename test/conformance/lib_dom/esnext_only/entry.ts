// With lib:["esnext"] (no "dom"), DOM globals are NOT in scope: each is a
// TS2304 "cannot find name", exactly as tsgo reports. Proves `lib` selection
// actually gates the DOM blob rather than always loading it.
const res: Response = null as any;
const r = fetch("/api");
const el: HTMLElement = null as any;
const u = new URLSearchParams();
