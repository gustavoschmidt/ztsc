// tsc's `discriminateContextualTypeByJSXAttributes`: the attribute list picks
// the one constituent of a union props type, exactly as an object literal's
// members do — so a render prop written against the surviving constituent gets
// a contextual signature instead of TS7006.
//
// Each parameter is pinned from BOTH sides (accepted as the winner's type,
// rejected as the loser's): a snapshot records only the code and the line.

declare namespace JSX {
    interface Element {}
    interface ElementAttributesProperty {
        props: {};
    }
    interface ElementChildrenAttribute {
        children: {};
    }
    interface IntrinsicElements {}
}

interface PS {
    multi: false;
    value: string | undefined;
    onChange: (selection: string | undefined) => void;
}
interface PM {
    multi: true;
    value: string[];
    onChange: (selection: string[]) => void;
}
declare function WithUnion(props: PM | PS): JSX.Element;

const a = (
    <WithUnion
        multi={false}
        value={"s"}
        onChange={(val) => {
            const ok: string | undefined = val;
            const bad: string[] = val; // TS2322
        }}
    />
);

// A valueless attribute is `true`, and an OPTIONAL discriminant the element
// leaves out discriminates by `undefined`.
type Props =
    | { renderNumber?: false; children: (arg: string) => void }
    | { renderNumber: true; children: (arg: number) => void };
declare function Foo(props: Props): JSX.Element;

const b = (
    <Foo>
        {(value) => {
            const ok: string = value;
            const bad: number = value; // TS2322
        }}
    </Foo>
);
const c = (
    <Foo renderNumber>
        {(value) => {
            const ok: number = value;
            const bad: string = value; // TS2322
        }}
    </Foo>
);
const d = (
    <Foo
        children={(value) => {
            const ok: string = value;
            const bad: number = value; // TS2322
        }}
    />
);
const e = (
    <Foo
        renderNumber
        children={(value) => {
            const ok: number = value;
            const bad: string = value; // TS2322
        }}
    />
);
