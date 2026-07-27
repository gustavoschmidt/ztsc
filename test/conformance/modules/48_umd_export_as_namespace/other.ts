// No import of "umdlib": `Lib` is reachable only as the UMD global.
export const viaGlobal: Lib.Options = { width: 1 };
export const viaGlobalBad: Lib.Options = { width: "x" };
export const mode: Lib.Mode = "fast";
export const modeBad: Lib.Mode = "medium";
