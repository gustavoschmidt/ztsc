class Node2 {
  value: number = 0;
  next: Node2 | null = null;
}
declare const n: Node2;
const v: number = n.next ? n.next.value : 0;
