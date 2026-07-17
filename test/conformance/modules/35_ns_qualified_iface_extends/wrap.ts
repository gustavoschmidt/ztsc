import * as mod from "./base";
// Heritage base reached through a namespace-import qualifier: the members of
// `mod.i18n` must be inherited (regression: they were silently lost).
export interface i18n extends mod.i18n {}
