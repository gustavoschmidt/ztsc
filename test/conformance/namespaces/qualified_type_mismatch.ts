namespace N {
  export interface Box {
    value: number;
  }
}

const bad: N.Box = { value: "not a number" };
