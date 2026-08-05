// tsc's endpoint analysis is CFA, not syntax: `functionHasImplicitReturn`
// reads `isReachableFlowNode(func.endFlowNode)`, whose Call arm ends the flow
// at a call whose signature returns `never`. So a trailing `never`-returning
// call makes the endpoint unreachable — no TS2366 and no phantom `| undefined`
// on an inferred return type. immich's `SharedLinkService.create` ends its
// `catch` with `this.handleError(error): never`.

declare function fail(e: unknown): never;

export function viaFreeFunction(x: number): string {
  if (x > 0) {
    return "a";
  }
  fail(x);
}

export function viaCatchClause(x: number): string {
  try {
    return "a";
  } catch (e) {
    fail(e);
  }
}

class Svc {
  private handleError(e: unknown): never {
    throw e;
  }
  viaMethod(x: number): string {
    try {
      return "a";
    } catch (e) {
      this.handleError(e);
    }
  }
}

export const svc = new Svc();

// The same answer drives the INFERRED return type: no phantom `| undefined`.
export function inferred(x: number) {
  if (x > 0) {
    return "a";
  }
  fail(x);
}
export const inferredIsString: string = inferred(1);

// Negative control: a call whose signature does NOT return `never` leaves the
// endpoint reachable, and so does a `never` call that is not the last thing on
// every path.
declare function noop(e: unknown): void;

export function stillMissing(x: number): string {
  if (x > 0) {
    return "a";
  }
  noop(x);
}

export function stillMissingBranch(x: number): string {
  if (x > 0) {
    fail(x);
  }
}
