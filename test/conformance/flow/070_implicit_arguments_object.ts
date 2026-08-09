// `arguments` is implicit in every non-arrow function body (tsc's
// `checkIdentifier` answers `getGlobalIArgumentsType()`), and an arrow
// borrows its enclosing function's. It is not in scope at the top level.
function classic(): number {
    const a: IArguments = arguments;
    return a.length;
}

const viaArrow = function () {
    const inner = () => arguments.length;
    return inner();
};

class C {
    m() {
        return arguments.length;
    }
}

// Top level: no enclosing function, so the name is genuinely not found.
const topLevel = arguments;

export { classic, viaArrow, C, topLevel };
