// `import <name>` followed by anything other than `,` or `from` is an
// ImportEqualsDeclaration whose `=` is missing — tsc's
// `tokenAfterImportedIdentifierDefinitelyProducesImportDeclaration`. The token
// that is not `=` stays UNCONSUMED, so a reserved word after the name goes back
// to the statement list and parses as itself.
import abstract class D {}

// A namespace import whose `as` is missing still reads the next token as the
// namespace name, so the rest of the clause keeps its bearings.
import * ns from "./missing";

class E extends D {}
