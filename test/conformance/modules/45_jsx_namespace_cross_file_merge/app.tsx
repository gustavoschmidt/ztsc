import { version } from "./react";

export const v: number = version;

// From the runtime's declaration…
export const a = <div id="x" />;
// …and from the project's, both through the one merged `JSX` namespace.
export const b = <em-emoji name="smile" />;
// Neither declares this one.
export const c = <nope-not-declared />; // TS2339
