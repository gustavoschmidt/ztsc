function unwrap<T>(box: { value: T }): T { return box.value; }
const n: number = unwrap({ value: 1 });
const s: string = unwrap({ value: "a" });
