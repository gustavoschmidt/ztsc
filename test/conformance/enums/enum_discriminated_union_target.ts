// An ENUM MEMBER is a unit type (tsc's `isUnitType` counts an "enum
// literal"), so it can be the discriminant of a discriminated union. A whole
// enum is not, which is why the test needs the type and not just its kind.
//
// `discriminatedUnionAssignable` — tsc's `typeRelatedToDiscriminatedType` —
// only accepted string/number/boolean/null/undefined/symbol tags, so a source
// object whose tag is an enum-member UNION was rejected by a union target that
// splits that tag across members, even though every combination fits. That is
// excalidraw's `Portal.broadcastScene`, which writes
// `SocketUpdateDataSource[typeof updateType]` for
// `updateType: WS_SUBTYPES.INIT | WS_SUBTYPES.UPDATE`.
enum W {
  Init = 'SCENE_INIT',
  Update = 'SCENE_UPDATE',
  Other = 'OTHER',
}

type Source = {
  SCENE_INIT: { type: W.Init; payload: { n: number } };
  SCENE_UPDATE: { type: W.Update; payload: { n: number } };
  OTHER: { type: W.Other };
};

declare const updateType: W.Init | W.Update;
declare const n: number;

export const ok: Source[typeof updateType] = {
  type: updateType,
  payload: { n },
};

// A tag constituent the target does not cover is still rejected…
declare const wide: W;
export const bad1: Source[W.Init | W.Update] = {
  type: wide,
  payload: { n },
};

// …and so is a non-discriminant property that does not fit.
export const bad2: Source[typeof updateType] = {
  type: updateType,
  payload: { n: 'x' },
};

// A single member still relates the ordinary way.
export const ok2: Source[W.Init] = { type: W.Init, payload: { n } };

// A whole-enum tag is not a unit, so it does not discriminate — the target
// member it does fit is still found.
type Loose = { type: W; payload: { n: number } } | { type: 'x' };
export const ok3: Loose = { type: wide, payload: { n } };
