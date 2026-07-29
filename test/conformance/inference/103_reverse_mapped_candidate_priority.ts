// tsc gives a REVERSE-MAPPED inference (`Partial<T>`, `Readonly<T>`, any
// homomorphic mapped parameter) `InferencePriority.HomomorphicMappedType` and
// keeps only the best-priority candidates. ztsc unioned the rebuilt object with
// the direct one, and the union was then not assignable back to the direct
// candidate's own type.

type V = { docked?: boolean; onDock?: (d: boolean) => void } & {
  onCloseRequest: () => void;
  shouldRenderDockButton: boolean;
};

declare const updateObject: <T extends Record<string, any>>(
  obj: T,
  updates: Partial<T>,
) => T;

export function f(
  cur: V,
  docked: boolean | undefined,
  onDock?: (d: boolean) => void,
) {
  const next: V = updateObject(cur, {
    docked,
    shouldRenderDockButton: !!onDock && docked != null,
  });
  return next;
}

// The direct candidate wins whichever ORDER the two parameters come in.
declare const updateObject2: <T extends Record<string, any>>(
  updates: Partial<T>,
  obj: T,
) => T;
export function g(cur: V) {
  const next: V = updateObject2({ shouldRenderDockButton: true }, cur);
  return next;
}

type Device = {
  editor: { isMobile: boolean; canFitSidebar: boolean };
  viewport: { isMobile: boolean; isLandscape: boolean };
  isTouchScreen: boolean;
};
export function h(d: Device) {
  const next: Device = updateObject(d, { isTouchScreen: true });
  return next;
}

// With NO direct candidate the reverse-mapped one is still the answer.
declare const fromUpdates: <T extends Record<string, any>>(
  updates: Partial<T>,
) => T;
export const a: { x?: number } = fromUpdates({ x: 1 });

// `Readonly<T>` is homomorphic too.
declare const ro: <T extends Record<string, any>>(o: T, r: Readonly<T>) => T;
export function i(cur: V) {
  const next: V = ro(cur, cur);
  return next;
}
