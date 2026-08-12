// The return-type inference probe walks a function's body just as
// `checkFunctionBody` later does, so it has to install the same receiver: an
// explicit `this` parameter types `this` inside the body. It did not, so the
// probe resolved `this.x` against the AMBIENT receiver — the enclosing class's
// instance or static side — and memoized that in `node_types`, where the real
// body walk read it back. Nothing is visible unless the enclosing class
// declares the same member NAME, which is exactly the shape of a static
// helper that forwards to a same-named inherited static.
//
// sequelize's `ModelStatic<M> = NonConstructor<typeof Model> & { new (): M }`
// is that shape: `createWithCtx<M extends Model>(this: ModelStatic<M>, …) {
// return this.create(values, …) }` resolved `create` on `typeof Model`, so
// `create`'s own `this: ModelStatic<M2>` was inferred from the class value and
// `M2` came out as the class's instance type instead of `M`. The helper's
// inferred return type became a concrete `Promise<Model<any, any>>` — no
// longer mentioning `M` — and every caller got it: 39 `Property 'x' does not
// exist on type 'Model<any, any>'` keys on outline.

interface FromThisType {
    tt: 1;
}
interface FromClass {
    cc: 1;
}

// (a) an INSTANCE method: the clash is with the class's own member. The
// discriminator is `bad`, which prints whichever `innerM` won.
class Inst {
    innerM(): FromClass {
        return null!;
    }
    outerM(this: { innerM(): FromThisType }) {
        const y = this.innerM();
        const bad: number = y;
        return y;
    }
}
// …and the answer is visible from outside too.
declare const inst: Inst;
export const fromInst: FromThisType = inst.outerM.call({ innerM: () => ({ tt: 1 }) as const });

// (b) a STATIC method: the clash is with the class's static side, and the
// `this` type carries the type parameter the forwarded call has to recover.
type Ctor<M> = new () => M;
class Stat {
    static innerM<M2 extends Stat>(this: StatOf<M2>): M2 {
        return new this();
    }
    static outerM<M extends Stat>(this: StatOf<M>) {
        return this.innerM();
    }
}
type StatOf<M> = { innerM<M2 extends Stat>(this: StatOf<M2>): M2 } & Ctor<M>;
class Derived extends Stat {
    only = 1;
}
export const derived: Derived = Derived.outerM();

// (c) the receiver annotation also has to be honoured when the member it
// names is ABSENT from it — the lookup must fail rather than fall through to
// the enclosing class.
class Absent {
    static innerM(): FromClass {
        return null!;
    }
    static outerM<M extends Absent>(this: Ctor<M>) {
        return this.innerM();
    }
}

// (d) an arrow body (no block) takes the same receiver.
class Expr {
    innerM(): FromClass {
        return null!;
    }
    outerM(this: { innerM(): FromThisType }) {
        const f = () => this.innerM();
        return f();
    }
}
declare const ex: Expr;
export const fromExpr: FromThisType = ex.outerM.call({ innerM: () => ({ tt: 1 }) as const });
