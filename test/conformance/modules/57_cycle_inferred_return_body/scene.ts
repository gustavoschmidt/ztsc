import { elementOverlapsWithFrame, getContainingFrame } from "./entry";
import type { El } from "./entry";

export type ElList = {
  filter: (cb: (element: El) => boolean) => ElList;
  some: (cb: (element: El) => boolean) => boolean;
};

export const getElementsWithinSelection = (
  elements: ElList,
  selection: El,
) => {
  let elementsInSelection = elements.filter((element) => {
    return element.id !== selection.id;
  });

  elementsInSelection = elementsInSelection.filter((element) => {
    const containingFrame = getContainingFrame(element);
    if (containingFrame) {
      return elementOverlapsWithFrame(element, containingFrame, elements);
    }
    return true;
  });

  return elementsInSelection;
};
