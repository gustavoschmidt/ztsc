enum Direction {
  Up,
  Down,
  Left,
  Right,
}

let d: Direction = Direction.Up;
let d2: Direction = Direction.Right;

function move(dir: Direction): Direction {
  return dir;
}

move(Direction.Down);
