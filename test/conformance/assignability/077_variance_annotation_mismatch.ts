// The DECLARATION-site check — that an annotation matches how the parameter is
// actually used — is not implemented (tsc's TS2636, registered in DEFERRED).
// The annotation is still honored at every USE site, which is what this case
// pins: `in T` is declared on a parameter used covariantly, and the assignment
// below goes by the annotation, not by the member.

interface Getter<in T> {
    get(): T;
}

declare const gu: Getter<unknown>;
const g1: Getter<string> = gu;
