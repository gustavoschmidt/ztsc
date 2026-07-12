interface Fish { swim: () => void; }
interface Bird { fly: () => void; }
function move(pet: Fish | Bird): void {
  if ("swim" in pet) { pet.swim(); } else { pet.fly(); }
}
