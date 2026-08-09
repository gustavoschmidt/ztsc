declare namespace JSX {
  interface Element {}
  interface IntrinsicAttributes {}
  interface IntrinsicElements {}
}

type OS = 'ios' | 'android' | 'native' | 'web'
declare function platform<T>(spec: {[p in OS]?: T}): T | undefined

type ButtonSize = 'large' | 'medium' | 'small' | 'tiny'
declare function Button(p: {label: string; size?: ButtonSize}): JSX.Element

// A CALL in an attribute value is contextually typed by the target prop, so
// the callee's generic inference gets the ReturnType-priority seed and the
// spec's fresh literals survive (T = "small" | "tiny").
const ok = (
  <Button
    label="x"
    size={platform({
      web: 'tiny',
      native: 'small',
    })}
  />
)

// The contextual type does not make a genuinely wrong result fit.
const bad = (
  <Button
    label="x"
    size={platform({
      web: 'nope',
      native: 'small',
    })}
  />
)

// A non-generic call is unaffected by the context.
declare function num(): number
const bad2 = <Button label="x" size={num()} />
