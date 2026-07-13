// An undefined decorator name is a real reference error: TS2304 "Cannot find
// name 'X'." — both on a class and on a class member.
@Missing
class A {}

class B {
  @nope field = 1;
  @gone method() {}
}
