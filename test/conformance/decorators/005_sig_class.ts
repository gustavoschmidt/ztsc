// TC39 class decorators (TS1238): a decorator whose call signature cannot
// accept the runtime-supplied (value, context) pair is "Unable to resolve
// signature of class decorator". A well-typed or `any`-typed one is accepted.
declare const ok: (value: Function, ctx: ClassDecoratorContext) => void;
declare const anyDeco: any;
declare const badValue: (value: string) => void;
declare const badCtx: (value: Function, ctx: ClassMethodDecoratorContext) => void;
declare const tooMany: (a: Function, b: ClassDecoratorContext, c: number) => void;
declare function okFactory(): (value: Function, ctx: ClassDecoratorContext) => void;
declare function badFactory(): (value: string) => void;

@ok
class A {}

@anyDeco
class B {}

@badValue
class C {}

@badCtx
class D {}

@tooMany
class E {}

@okFactory()
class F {}

@badFactory()
class G {}
