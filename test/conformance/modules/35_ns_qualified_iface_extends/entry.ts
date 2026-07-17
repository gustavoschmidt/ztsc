import { i18n } from "./wrap";
declare const x: i18n;
const a: string = x.t("hi");
const b: string = x.language;
// Proves `t` is inherited: omitting it is the sole error.
const bad: i18n = { language: "en" };
