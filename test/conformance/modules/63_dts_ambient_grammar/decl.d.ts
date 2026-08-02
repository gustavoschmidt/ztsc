// A top-level declaration in a `.d.ts` must start with `declare` or `export`
// (TS1046 — tsc reports the FIRST offender only), and an ambient context
// allows no initializers (TS1039) except on a `const` with no annotation.
var version = "0.33.0";

declare var v1 = 1;
declare let v2 = 2;
declare const v3 = 3;
declare const v4: number = 4;

declare namespace N {
    var inner = 5;
    const innerOk = 6;
}

declare const compatibilityVersion = 7;

export { compatibilityVersion, version as npmVersion };
