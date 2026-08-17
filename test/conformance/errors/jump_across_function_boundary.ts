// TS1107: a `break`/`continue` may not jump out of the function it sits in.
// tsc walks out of the statement looking for an iteration statement, a
// `switch` or a matching label, and answers the moment it reaches a
// function-like instead — so the enclosing `while` and the enclosing label
// below are invisible from inside the nested function.
//
// Everything that resolves WITHIN its own function is silent, including a
// labeled block, a `switch`, and a label re-used inside the nested function.
declare const c: boolean;

while (c) {
  function crossesUnlabeled(): void {
    break;
  }
  function crossesUnlabeledContinue(): void {
    continue;
  }
}

target: while (c) {
  function crossesLabel(): void {
    while (c) {
      break target;
    }
  }
  const arrow = (): void => {
    continue target;
  };
}

function ownTargets(): void {
  while (c) {
    break;
  }
  do {
    continue;
  } while (c);
  for (let i = 0; i < 1; i++) {
    break;
  }
  for (const k in {}) {
    continue;
  }
  for (const v of []) {
    break;
  }
  switch (1) {
    case 1:
      break;
  }
  inner: {
    break inner;
  }
  target: while (c) {
    break target;
  }
}
