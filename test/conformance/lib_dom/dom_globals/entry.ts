// DOM globals resolve when tsconfig `lib` includes "dom".
const res: Response = new Response("body");
const el: HTMLElement = document.createElement("div");
const p: Promise<Response> = fetch("/api");
const q: Element | null = document.querySelector("div");
console.log(res, el, p, q);
