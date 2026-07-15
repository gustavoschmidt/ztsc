import * as React from "react";
import { Button, Panel, Badge, ButtonProps } from "./components";

// --- correct usage: must stay clean -----------------------------------
const good = (
  <Panel title="Toolbar" key="toolbar">
    <Button label="Save" kind="primary" onPress={() => {}} />
    <Badge count={3} max={9} />
    <div className="spacer" style={{ width: 8 }} />
  </Panel>
);

const forwarded: ButtonProps = { label: "Reset", kind: "ghost" };
const viaSpread = <Button {...forwarded} />;
const overridden = <Button {...forwarded} label="Cancel" />;

// --- planted mistakes (each line must match tsgo exactly) --------------
// 1. wrong attribute value type
const m1 = <Button label={42} />;
// 2. missing required prop
const m2 = <Button kind="ghost" />;
// 3. excess prop on a component
const m3 = <Button label="Go" volume={11} />;
// 4. spread that misses a required prop
const partial = { kind: "ghost" as const };
const m4 = <Button {...partial} />;
// 5. non-object spread
const m5 = <Button {..."props"} />;
// 6. literal attr overwritten by a later spread
const m6 = <Button label="Old" {...forwarded} />;
// 7. missing children (required by PanelProps)
const m7 = <Panel title="Empty" />;
// 8. wrong attribute type on an intrinsic element
const m8 = <div id={123} />;
// 9. unknown attribute on an intrinsic element
const m9 = <span volume={11} />;
