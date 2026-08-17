// tsc parses decorators and modifiers as ONE list, in either order, so a
// decorator may sit on either side of the `export` that precedes a class.
// Both orders are silent — this case must be diagnostic-free.
declare const dec: any;

@dec
export class Before {}

export @dec class After {}

export
@dec
@dec
class Stacked {}

@dec
export default class Defaulted {}
