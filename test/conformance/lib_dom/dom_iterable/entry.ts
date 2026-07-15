// dom.iterable: a DOM collection (NodeListOf) is iterable with for...of when
// "dom" is selected (its `[Symbol.iterator]` comes from the DOM lib).
const nodes = document.querySelectorAll("div");
for (const n of nodes) {
  n.tagName;
}
const chars = "abc";
for (const ch of chars) {
  ch.toUpperCase();
}
