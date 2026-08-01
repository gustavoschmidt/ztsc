// The DECLARATION-site check (TS2636): the annotation must match how the
// parameter is actually used. `in T` is declared on a parameter used
// covariantly, so line 7 is flagged — measured by relating the two marker
// instantiations of `Getter`. The annotation is still honored at every USE
// site, so the assignment below goes by it rather than by the member.

interface Getter<in T> {
    get(): T;
}

declare const gu: Getter<unknown>;
const g1: Getter<string> = gu;
