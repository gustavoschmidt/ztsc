// Where TS2411/TS2413 land: tsc blames the DECLARATION, and a declaration
// starts at its modifiers — or, for a constructor parameter property, at the
// parameter.

// A parameter property declares an instance member as surely as a field does,
// and is judged against the index signature the same way.
class ParamProps {
    [k: string]: number;
    constructor(
        public bad: string,
        private alsoBad: boolean,
        readonly fine: number,
        plain: string,
    ) {}
}

// The index-signature site includes the member's modifiers.
interface Modified {
    readonly [s: string]: number;
    readonly [s: number]: string;
}

class StaticModified {
    static readonly [s: string]: number;
    static readonly [s: number]: string;
}

export { ParamProps, StaticModified };
export type { Modified };
