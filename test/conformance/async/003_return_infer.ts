async function h() { return 1; }
async function e() {}
const good: Promise<number> = h();
const bad: Promise<string> = h();
const v: Promise<void> = e();
