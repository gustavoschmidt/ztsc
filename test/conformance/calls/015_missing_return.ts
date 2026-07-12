function f(): number {}
declare const c: boolean;
function g(): number { if (c) { return 1; } }
function h(): number { if (c) { return 1; } return 2; }
