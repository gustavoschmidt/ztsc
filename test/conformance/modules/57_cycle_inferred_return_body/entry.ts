import { getElementsWithinSelection } from "./scene";
import type { ElList } from "./scene";

export type El = { id: string; frameId: string | null };

export const isElementContainingFrame = (
  element: El,
  frame: El,
  all: ElList,
) => {
  return getElementsWithinSelection(all, element).some(
    (e) => e.id === frame.id,
  );
};

export const elementOverlapsWithFrame = (
  element: El,
  frame: El,
  all: ElList,
) => {
  return isElementContainingFrame(element, frame, all);
};

export const getContainingFrame = (element: El) => {
  if (!element.frameId) {
    return null;
  }
  return null as null | El;
};
