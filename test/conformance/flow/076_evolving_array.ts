// tsc's evolving array. A variable initialized with a bare `[]` has no
// declared type: it gets `autoArrayType`, and control flow analysis GROWS it
// from `x.push(v)`, `x.unshift(v)` and `x[i] = v` until a read finalizes it
// into a real `T[]` — `any[]` while nothing has gone in, which is where the
// TS7034/TS7005 pair comes from.
//
// Each fact is pinned from BOTH sides where a snapshot could not otherwise
// tell the types apart: the evolved reading is accepted at one line and the
// reading it replaced is rejected at the next.

declare function cond(): boolean;

function pushes_grow_it() {
    let x = [];
    x.push(1);
    const evolved: number[] = x;
    const not_any: string[] = x; // TS2322 — `number[]`, not `any[]`
}

function unshift_grows_it_too() {
    let x = [];
    x.unshift("s");
    const evolved: string[] = x;
    const not_number: number[] = x; // TS2322
}

function element_writes_grow_it() {
    let x = [];
    x[0] = 1;
    const evolved: number[] = x;
    const not_string: string[] = x; // TS2322
}

function every_argument_joins_the_element_type() {
    let x = [];
    x.push(1, "s");
    const evolved: (string | number)[] = x;
    const not_number_only: number[] = x; // TS2322
}

// A SPREAD contributes the elements of what it spreads, not the array.
function a_spread_contributes_its_elements() {
    let x = [];
    x.push(...["a", "b"]);
    const evolved: string[] = x;
    const not_nested: string[][] = x; // TS2322
}

// A read BEFORE anything went in is the implicit `any[]` pair, and a read
// after is not.
function a_read_before_the_first_push_is_an_implicit_any() {
    let x = []; // TS7034
    const before = x; // TS7005
    x.push(1);
    const after = x;
    const after_is_number: number[] = after;
}

// The array survives a condition that does not narrow it.
function a_condition_does_not_finalize_it() {
    let x = [];
    if (x.length === 0) {
        x.push(1);
    }
    const evolved: number[] = x;
    const not_any: string[] = x; // TS2322
}

// Branches that are ALL evolving join into one evolving array…
function a_join_of_evolving_branches_keeps_evolving() {
    let x = [];
    if (cond()) {
        x.push(1);
    } else {
        x.push("s");
    }
    const evolved: (string | number)[] = x;
}

// …but a branch that assigns a real array makes the join an ordinary union,
// which is what stops the later `push` from being accepted.
function one_concrete_branch_finalizes_the_join() {
    let x;
    if (cond()) {
        x = [];
        x.push(1);
    } else {
        x = [true];
    }
    const joined: boolean[] | number[] = x;
    const not_one_array: number[] = x; // TS2322
}

// `let x;` reaches the same state through an `x = []` assignment.
function an_empty_array_assignment_starts_one() {
    let x; // TS7034
    x = [];
    const before = x; // TS7005
    x.push(1);
    const after: number[] = x;
}

// A `const` evolves too — tsc's `NodeFlags.Constant` guard sits on the
// null/undefined branch of the auto type, not on the empty-array one.
function a_const_evolves() {
    const x = [];
    x.push(1);
    const evolved: number[] = x;
    const not_any: string[] = x; // TS2322
}

// A `const` evolving array does NOT carry across a closure: tsc's
// closure-crossing loop admits a constant only when its type is not the auto
// array, so the capture is back at the auto array and reports.
function a_const_one_does_not_cross_a_closure() {
    const x = []; // TS7034
    x.push(1);
    const f = () => {
        const captured = x; // TS7005
    };
}

// A never-reassigned `let` DOES cross: it is past its last assignment, so the
// analysis extends into the enclosing function and the evolved type survives.
function a_let_one_crosses_a_closure() {
    let x = [];
    x.push(1);
    const f = () => {
        const captured: number[] = x;
        const not_any: string[] = x; // TS2322
    };
}

// A read in an OPERATION-TARGET position — `x.length`, `x.push(…)`,
// `x[i] = v` — answers with the auto array rather than with what has gone in
// so far, so a second push of a different type is not checked against the
// first, and the read itself is exempt from the pair.
function an_operation_target_is_exempt() {
    let x = [];
    x.push(1);
    x.push("s"); // not an error: the receiver reads as `any[]`
    x.length;
    const evolved: (string | number)[] = x;
}

// The exemption is the READ's, not the variable's: a copy taken out of the
// array is an ordinary array and IS checked.
function a_copy_is_not_exempt() {
    let x = [];
    x.push(1);
    const y = x;
    y.push("s"); // TS2345 — `y` is `number[]`
}
