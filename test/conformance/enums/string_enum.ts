enum Color {
  Red = "RED",
  Green = "GREEN",
  Blue = "BLUE",
}

let c: Color = Color.Red;
let s: string = Color.Green;

function toLabel(value: Color): string {
  return value;
}

toLabel(Color.Blue);
