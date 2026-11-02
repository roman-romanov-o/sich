import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { SANS } from "../fonts";
import { CAPTIONS, Caption, EASE_OUT, FPS } from "../timeline";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** Kinetic captions, timed in footage seconds. */
export const Captions: React.FC = () => {
  const t = useCurrentFrame() / FPS;
  return (
    <AbsoluteFill>
      {CAPTIONS.map((c) => (t >= c.from - 0.05 && t <= c.to + 0.3 ? <Line key={c.text} c={c} t={t} /> : null))}
    </AbsoluteFill>
  );
};

const Line: React.FC<{ c: Caption; t: number }> = ({ c, t }) => {
  const enter = interpolate(t, [c.from, c.from + 0.45], [0, 1], { ...clamp, easing: EASE_OUT });
  const leave = interpolate(t, [c.to, c.to + 0.25], [0, 1], clamp);
  // `*…*` spans are accented; split into words that remember their span.
  const words = c.text
    .split("*")
    .flatMap((part, i) => part.split(" ").filter(Boolean).map((w) => ({ w, accent: i % 2 === 1 })));
  return (
    <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", paddingBottom: 46 }}>
      <div
        style={{
          fontFamily: SANS,
          fontSize: 50,
          fontWeight: 600,
          letterSpacing: -0.8,
          color: "#f2f3f5",
          padding: "18px 34px",
          borderRadius: 999,
          background: "rgba(12,14,19,0.78)",
          backdropFilter: "blur(18px)",
          boxShadow: "0 0 0 1px rgba(255,255,255,0.10), 0 18px 50px rgba(0,0,0,0.55)",
          opacity: enter * (1 - leave),
          translate: `0px ${interpolate(enter, [0, 1], [26, 0]) - leave * 10}px`,
          filter: `blur(${(1 - enter) * 8 + leave * 6}px)`,
          display: "flex",
          gap: "0.26em",
        }}
      >
        {words.map(({ w, accent }, i) => {
          const appear = interpolate(t, [c.from + i * 0.04, c.from + i * 0.04 + 0.35], [0, 1], { ...clamp, easing: EASE_OUT });
          return (
            <span
              key={i}
              style={{
                color: accent ? c.accent : undefined,
                opacity: appear,
                translate: `0px ${(1 - appear) * 14}px`,
              }}
            >
              {w}
            </span>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
