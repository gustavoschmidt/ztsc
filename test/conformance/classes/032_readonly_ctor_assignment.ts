// A `readonly` property may be assigned via `this.x` inside the constructor of
// the class that OWNS the declaration (tsc's `checkReferenceExpression`), even
// when the field also has an initializer. Assignment elsewhere — a method, or a
// subclass constructor for an INHERITED readonly — still errors TS2540.
// Minimized repro of the dogfood project's ApiAdapter constructor.

class Service {}

class ApiAdapter extends Service {
  private readonly dbPromise: string;
  private readonly enableLocalCache: boolean = false;
  private readonly baseUrl: string;

  constructor(baseUrl: string, enableLocalCache: boolean = false) {
    super();
    this.enableLocalCache = enableLocalCache; // OK: own readonly in ctor
    this.baseUrl = baseUrl; // OK
    this.dbPromise = "p"; // OK
  }

  // NEGATIVE: assignment outside the constructor still errors.
  reset() {
    this.baseUrl = "x"; // error TS2540
  }
}

// NEGATIVE: a subclass constructor may not assign an INHERITED readonly.
class Base {
  protected readonly token: string = "t";
}
class Sub extends Base {
  constructor() {
    super();
    this.token = "u"; // error TS2540: inherited readonly, not own
  }
}

new ApiAdapter("u").reset();
new Sub();
