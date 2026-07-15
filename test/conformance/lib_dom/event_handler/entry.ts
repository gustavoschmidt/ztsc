// DOM event types (MouseEvent/UIEvent/EventTarget) resolve and type
// event-handler callbacks when "dom" is selected.
const btn = document.createElement("button");
btn.addEventListener("click", (event: MouseEvent) => {
  event.preventDefault();
  const t: EventTarget | null = event.currentTarget;
  t;
});
function onResize(e: UIEvent): void {
  e.type;
}
window.addEventListener("resize", onResize);
