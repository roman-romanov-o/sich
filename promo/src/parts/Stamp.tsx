import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { MONO } from "../fonts";
import { EASE_OUT, FPS, STAMPS } from "../timeline";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** A stamp at the top: fast-forward over a time-lapse, or the shortcut being pressed. */
export const Stamp: React.FC = () => {
  const t = useCurrentFrame() / FPS;
  const stamp = STAMPS.find((l) => t >= l.from && t <= l.to + 0.3);
  if (!stamp) return null;
  const enter = interpolate(t, [stamp.from, stamp.from + 0.3], [0, 1], { ...clamp, easing: EASE_OUT });
  const leave = interpolate(t, [stamp.to, stamp.to + 0.3], [0, 1], clamp);
  return (
    <AbsoluteFill style={{ alignItems: "center", paddingTop: 48 }}>
      <div
        style={{
          fontFamily: MONO,
          fontSize: 40,
          color: stamp.color,
          padding: "12px 28px",
          borderRadius: 999,
          background: "rgba(12,14,19,0.8)",
          boxShadow: `0 0 0 1px ${stamp.color}73, 0 14px 40px rgba(0,0,0,0.5)`,
          opacity: enter * (1 - leave),
          translate: `0px ${(1 - enter) * -20}px`,
        }}
      >
        {stamp.text}
      </div>
    </AbsoluteFill>
  );
};
