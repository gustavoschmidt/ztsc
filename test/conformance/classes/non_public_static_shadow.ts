// TS2417 for a `private`/`protected` STATIC that shadows a base static.
//
// The `private`/`protected` screen inside the relation compares the two
// property SYMBOLS, which ztsc rediscovers by walking the receiver's declared
// heritage. A class's static side is a plain materialized object with no
// reference to walk from, so every static shadow used to answer "no
// declaration side" — which the rule reads as "related" — and TS2417 never
// fired. `classStaticType`'s reverse index supplies the class.

// Two separate `private static` declarations of the same name.
class Base2 {
    private static y: { foo: string };
}
class Derived2 extends Base2 {
    private static y: { foo: string; bar: string };
}

// `private static` over a `public static`: the private side names `typeof C`,
// not the bare class, which is how tsc prints the static side.
class PubBase {
    public static x: string;
    public static fn(): string {
        return "";
    }
}
class PrivDerived extends PubBase {
    private static x: string;
    private static fn(): string {
        return "";
    }
}

// `protected static` over a `public static` — the other one-sided arm.
class PubBase2 {
    static r: { foo: string };
}
class ProtDerived extends PubBase2 {
    protected static r: { foo: string };
}

// NOT an error: an INHERITED private static is one declaration seen from both
// sides, so a derived class that redeclares nothing still extends its base.
class Keeper {
    private static k: string;
}
class KeeperSub extends Keeper {}
declare const ks: typeof KeeperSub;
declare const kp: typeof Keeper;
export const keeps: typeof Keeper = ks;
export const keeps2: typeof KeeperSub = kp;

// NOT an error: the INSTANCE side of the same shape is untouched by the static
// index, and a public static shadow is plain overriding.
class OkBase {
    static v: string;
}
class OkDerived extends OkBase {
    static v: string;
}
export const ok: typeof OkBase = OkDerived;
