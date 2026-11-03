import { Easing, interpolate } from "remotion";
import beatList from "../public/beats.json";

/** When each story beat fired in the recorded footage, in footage seconds. */
const beatTimes = Object.fromEntries(beatList.map((b) => [b.name, b.t]));
export const beat = (name: string): number => {
  const t = beatTimes[name];
  if (t === undefined) throw new Error(`footage has no beat "${name}"`);
  return t;
};

export const FPS = 30;
export const INTRO_FRAMES = 66;
/** The footage starts while the intro title is still leaving. */
export const FOOTAGE_FROM = 54;
export const FOOTAGE_SECONDS = beat("end");
export const OUTRO_FROM = FOOTAGE_FROM + Math.round((FOOTAGE_SECONDS - 0.4) * FPS);
export const OUTRO_FRAMES = 110;
export const TOTAL_FRAMES = OUTRO_FROM + OUTRO_FRAMES;

export const EASE = Easing.bezier(0.65, 0, 0.35, 1);
export const EASE_OUT = Easing.bezier(0.16, 1, 0.3, 1);

/** Footage point the camera centres on (0..1 of the window) and its zoom. */
export type Shot = { t: number; x: number; y: number; zoom: number };

const B = {
  focus: beat("focus"),
  drill: beat("drill-in"),
  type: beat("type"),
  back: beat("back"),
  timelapse: beat("timelapse"),
  rest: beat("rest"),
  breakLapse: beat("break-timelapse"),
  tray: beat("tray"),
  release: beat("release"),
  interrupt: beat("interrupt"),
  switch1: beat("switch"),
  commit1: beat("commit"),
  answer1: beat("answer"),
  switch2: beat("switch-2"),
  commit2: beat("commit-2"),
  answer2: beat("answer-2"),
  clear: beat("clear"),
  pull: beat("pull"),
  type3: beat("type-3"),
};
export { B };

const WIDE = { x: 0.5, y: 0.56, zoom: 0.92 };
const RING = { x: 0.85, y: 0.74, zoom: 2.0 };
const TERMINAL = { x: 0.5, y: 0.5, zoom: 1.1 };
const PROMPT = { x: 0.43, y: 0.55, zoom: 1.5 };
const NEEDS_YOU = { x: 0.42, y: 0.32, zoom: 1.75 };
const HELD_NOTE = { x: 0.84, y: 0.86, zoom: 2.1 };
const REST = { x: 0.5, y: 0.53, zoom: 1.35 };
const TRAY = { x: 0.5, y: 0.6, zoom: 1.65 };
const SWITCHER = { x: 0.5, y: 0.47, zoom: 1.5 };
const DIALOG = { x: 0.475, y: 0.58, zoom: 1.45 };
const NEW_TASK = { x: 0.45, y: 0.33, zoom: 1.45 };
const BACKLOG = { x: 0.27, y: 0.3, zoom: 1.6 };

export const SHOTS: Shot[] = [
  { t: 0, ...WIDE },
  { t: B.focus - 1.0, ...WIDE },
  { t: B.focus - 0.2, ...RING },
  { t: B.drill - 1.5, ...RING },
  { t: B.drill - 0.7, ...WIDE },
  { t: B.drill + 0.45, ...TERMINAL },
  { t: B.type - 0.1, ...TERMINAL },
  { t: B.type + 0.6, ...PROMPT },
  { t: B.back - 0.3, ...PROMPT },
  { t: B.back + 0.5, ...NEEDS_YOU },
  { t: B.back + 1.6, ...NEEDS_YOU },
  { t: B.back + 2.3, ...HELD_NOTE },
  { t: B.timelapse - 0.1, ...HELD_NOTE },
  { t: B.timelapse + 0.4, ...RING },
  { t: B.rest - 0.6, ...RING },
  { t: B.rest - 0.1, ...REST },
  { t: B.tray - 0.2, ...REST },
  { t: B.tray + 0.4, ...TRAY },
  { t: B.release - 0.2, ...TRAY },
  { t: B.release + 0.5, ...WIDE },
  { t: B.switch1 - 0.1, ...WIDE },
  { t: B.switch1 + 0.4, ...SWITCHER },
  { t: B.commit1 - 0.1, ...SWITCHER },
  { t: B.commit1 + 0.5, ...DIALOG },
  { t: B.switch2 - 0.1, ...DIALOG },
  { t: B.switch2 + 0.4, ...SWITCHER },
  { t: B.commit2 - 0.1, ...SWITCHER },
  { t: B.commit2 + 0.5, ...DIALOG },
  { t: B.clear - 0.1, ...DIALOG },
  { t: B.clear + 0.5, ...WIDE },
  { t: B.clear + 1.0, ...WIDE },
  { t: B.clear + 1.6, ...BACKLOG },
  { t: B.pull - 1.4, ...BACKLOG },
  { t: B.pull + 0.45, ...TERMINAL },
  { t: B.type3 - 0.1, ...TERMINAL },
  { t: B.type3 + 0.6, ...NEW_TASK },
];

/** Camera at footage time `t`; zoom moves in log space so push-ins feel even. */
export const cameraAt = (t: number): Omit<Shot, "t"> => {
  const i = SHOTS.findIndex((s) => s.t > t);
  if (i === -1) return SHOTS[SHOTS.length - 1];
  if (i === 0) return SHOTS[0];
  const a = SHOTS[i - 1];
  const b = SHOTS[i];
  const p = interpolate(t, [a.t, b.t], [0, 1], { easing: EASE });
  return {
    x: a.x + (b.x - a.x) * p,
    y: a.y + (b.y - a.y) * p,
    zoom: Math.exp(Math.log(a.zoom) + (Math.log(b.zoom) - Math.log(a.zoom)) * p),
  };
};

/** A caption on screen between two footage times; `*…*` marks the accent. */
export type Caption = { from: number; to: number; text: string; accent?: string };

const BLUE = "#7aa2f7";
const GREEN = "#9ece6a";
const TEAL = "#7dcfff";
const AMBER = "#e0af68";

export const CAPTIONS: Caption[] = [
  { from: 0.9, to: B.focus - 0.9, text: "Five agents working. *One of you.*", accent: BLUE },
  { from: B.focus - 0.5, to: B.drill - 0.9, text: "Start a *focus block.*", accent: AMBER },
  { from: B.drill - 0.6, to: B.type + 0.3, text: "Pick *one task* and go deep.", accent: BLUE },
  { from: B.type + 0.45, to: B.back - 0.1, text: "Steer it in a *real terminal.*", accent: BLUE },
  { from: B.back + 0.15, to: B.back + 1.9, text: "Other agents ask for you…", accent: BLUE },
  { from: B.back + 2.1, to: B.timelapse + 0.1, text: "…and *wait for your break.* No pings.", accent: TEAL },
  { from: B.timelapse + 0.3, to: B.rest - 0.4, text: "25 minutes on *one thing.*", accent: AMBER },
  { from: B.rest - 0.1, to: B.tray - 0.3, text: "Then a *real break.* Breathe.", accent: TEAL },
  { from: B.tray + 0.1, to: B.release - 0.2, text: "Their questions return as *one calm list.*", accent: GREEN },
  { from: B.release + 0.1, to: B.switch1 - 0.3, text: "Now *answer them,* one by one.", accent: GREEN },
  { from: B.switch1 + 0.1, to: B.commit1 - 0.2, text: "*⌃Tab* jumps to who needs you.", accent: BLUE },
  { from: B.commit1 + 0.2, to: B.switch2 - 0.3, text: "Answer it *right in its terminal.*", accent: BLUE },
  { from: B.switch2 + 0.1, to: B.answer2 - 0.2, text: "*⌃Tab* again. Next question.", accent: BLUE },
  { from: B.answer2 + 0.1, to: B.clear + 0.6, text: "Everyone's *unblocked.*", accent: GREEN },
  { from: B.clear + 0.9, to: B.pull - 0.2, text: "Nobody waiting? *Take the next task* from the backlog.", accent: TEAL },
  { from: B.pull + 0.2, to: beat("end") + 0.2, text: "Then *focus again.*", accent: AMBER },
];

/** Stamps at the top: fast-forwards over the time-lapses, keycaps over shortcuts. */
export type Stamp = { from: number; to: number; text: string; color: string };
export const STAMPS: Stamp[] = [
  { from: B.timelapse, to: B.rest - 0.2, text: "⏩  25 min", color: AMBER },
  { from: B.breakLapse, to: B.tray - 0.1, text: "⏩  5 min", color: AMBER },
  { from: B.switch1 - 0.15, to: B.commit1, text: "⌃ Tab", color: BLUE },
  { from: B.switch2 - 0.15, to: B.commit2, text: "⌃ Tab", color: BLUE },
];

/** Each glide ends in a click a beat before the app reacts. */
export type Click = { from: { x: number; y: number }; to: { x: number; y: number }; appear: number; arrive: number; click: number; hide: number };
export const CLICKS: Click[] = [
  { from: { x: 0.7, y: 0.58 }, to: { x: 0.885, y: 0.79 }, appear: B.focus - 1.0, arrive: B.focus - 0.3, click: B.focus - 0.1, hide: B.focus + 0.7 },
  { from: { x: 0.62, y: 0.5 }, to: { x: 0.32, y: 0.16 }, appear: B.drill - 1.3, arrive: B.drill - 0.35, click: B.drill - 0.15, hide: B.drill + 0.05 },
  { from: { x: 0.4, y: 0.45 }, to: { x: 0.07, y: 0.17 }, appear: B.pull - 1.3, arrive: B.pull - 0.35, click: B.pull - 0.15, hide: B.pull + 0.05 },
];

/** A stretch of footage, in footage seconds; `captions` replaces the tour's own. */
export type Cut = { from: number; to: number; captions?: Caption[] };

/** The short README clips, each a few cuts of the same footage played back to back. */
export const CLIPS: Record<string, Cut[]> = {
  // The board leads; the pomodoro is the supporting act at the end.
  Hero: [
    {
      from: B.release + 0.55,
      to: B.answer1 + 0.5,
      captions: [
        { from: B.release - 0.3, to: B.switch1 - 0.3, text: "Every agent on *one board.*", accent: BLUE },
        ...CAPTIONS.filter((c) => c.from >= B.switch1),
      ],
    },
    { from: B.clear + 0.35, to: B.pull - 0.05 },
    { from: B.back - 0.2, to: B.timelapse + 0.1 },
    { from: B.rest - 0.1, to: B.breakLapse - 0.1 },
  ],
  Terminal: [{ from: B.drill + 0.1, to: B.interrupt - 0.2 }],
  Switch: [{ from: B.switch1 - 0.5, to: B.answer2 + 0.9 }],
  Backlog: [{ from: B.clear + 0.35, to: beat("end") - 0.8 }],
};
export const CUT_FADE = 6;
export const clipFrames = (cuts: Cut[]) => cuts.reduce((n, c) => n + Math.round((c.to - c.from) * FPS), 0);
