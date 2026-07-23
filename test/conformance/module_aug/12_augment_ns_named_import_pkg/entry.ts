import { DrawEvents, LeafletEventHandlerFn } from "evtlib";
import "evtlib-plugin";

// DrawStop extends LeafletEvent, so a `(e: DrawStop) => void` is castable to a
// `(event: LeafletEvent) => void` handler — the heritage must materialize.
const h = ((e: DrawEvents.DrawStop) => {}) as LeafletEventHandlerFn;

// Inherited member visible via the augmentation heritage.
function f(e: DrawEvents.DrawStop): string {
  return e.type;
}
// Own member visible.
function g(e: DrawEvents.DrawStop): string {
  return e.layerType;
}
// Negative control: absent everywhere → TS2339.
function bad(e: DrawEvents.DrawStop): number {
  return e.missing;
}
