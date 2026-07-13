// A property-access decorator `@ns.deco` resolves the object then the member.
// A valid access is clean; an undefined base object is TS2304.
declare const ns: { deco: any };

@ns.deco
class A {}

@goneNs.deco
class B {}
