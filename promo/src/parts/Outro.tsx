import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { MONO, SANS } from "../fonts";
import { EASE_OUT } from "../timeline";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

const rise = (frame: number, at: number) => ({
  opacity: interpolate(frame, [at, at + 12], [0, 1], clamp),
  translate: `0px ${interpolate(frame, [at, at + 18], [28, 0], { ...clamp, easing: EASE_OUT })}px`,
  filter: `blur(${interpolate(frame, [at, at + 12], [8, 0], clamp)}px)`,
});

export const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", fontFamily: SANS }}>
      <Img
        src={staticFile("icon.png")}
        style={{ borderRadius: "23%",
          width: 150,
          height: 150,
          marginBottom: 40,
          scale: interpolate(frame, [0, 20], [0.5, 1], { ...clamp, easing: EASE_OUT }),
          opacity: interpolate(frame, [0, 8], [0, 1], clamp),
          filter: "drop-shadow(0 20px 50px rgba(122,162,247,0.35))",
        }}
      />
      <div style={{ fontSize: 96, fontWeight: 800, letterSpacing: -3, color: "#f5f6f8", ...rise(frame, 6) }}>
        Many agents. One focus.
      </div>
      <div style={{ fontSize: 56, fontWeight: 500, letterSpacing: -0.8, color: "rgba(230,233,240,0.7)", marginTop: 14, ...rise(frame, 14) }}>
        Their questions wait for <span style={{ color: "#7dcfff" }}>your break</span>.
      </div>
      <div
        style={{
          marginTop: 64,
          display: "flex",
          alignItems: "center",
          gap: 26,
          ...rise(frame, 26),
        }}
      >
        <div
          style={{
            fontFamily: MONO,
            fontSize: 38,
            color: "#f2f3f5",
            padding: "16px 30px",
            borderRadius: 18,
            background: "rgba(122,162,247,0.12)",
            boxShadow: "0 0 0 1px rgba(122,162,247,0.45)",
          }}
        >
          github.com/roman-romanov-o/sich
        </div>
      </div>
      <div style={{ marginTop: 28, fontSize: 34, fontWeight: 500, color: "rgba(230,233,240,0.5)", ...rise(frame, 34) }}>
        Free · MIT · native macOS
      </div>
    </AbsoluteFill>
  );
};
