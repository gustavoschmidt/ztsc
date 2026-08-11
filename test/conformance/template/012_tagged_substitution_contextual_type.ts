// A tagged template's substitutions are the tag call's ARGUMENTS, so each is
// contextually typed by the tag's parameter at its position. Every real
// template tag collects them through a REST parameter, and a styled-components
// interpolation is an arrow whose parameter has no annotation at all — with no
// contextual type it is implicit `any`.
type Value = string | number | undefined | null | false;
type Fn<P> = (props: P) => Value;
type Interp<P> = Value | Fn<P>;

// (1) a rest whose element type is a UNION with one function member
declare function tpl<U extends object>(
  first: TemplateStringsArray,
  ...rest: Array<Interp<{ theme: string } & U>>
): string;
export const s1 = tpl<{ $size: number }>`w: ${(props) => props.$size}px`;

// (2) a rest whose element type is the bare function type
declare function tpl2<U extends object>(
  first: TemplateStringsArray,
  ...rest: Array<Fn<{ theme: string } & U>>
): string;
export const s2 = tpl2<{ $size: number }>`w: ${(props) => props.$size}px`;

// (3) no generics
declare function tpl3(
  first: TemplateStringsArray,
  ...rest: Array<(props: { theme: string }) => string>
): string;
export const s3 = tpl3`w: ${(props) => props.theme}px`;

// (4) a FIXED parameter, not a rest
declare function tpl4(
  first: TemplateStringsArray,
  one: (props: { theme: string }) => string
): string;
export const s4 = tpl4`w: ${(props) => props.theme}px`;

// The contextual type is a type, not a licence: a substitution that really is
// wrong still says so.
export const s5 = tpl3`w: ${(props) => props.nope}px`;

// A tag with no call signature at all leaves the substitutions unctx-typed,
// but they are still checked.
declare const notATag: number;
export const s6 = (notATag as any)`w: ${(props: { a: number }) => props.b}px`;
