class Counter {
  count: number = 0;
  bump(): number { return this.count + 1; }
  bad(): string { return this.count; }
}
