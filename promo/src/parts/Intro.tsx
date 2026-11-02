import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { SANS } from "../fonts";
import { EASE, EASE_OUT, INTRO_FRAMES } from "../timeline";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

export const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const out = interpolate(frame, [INTRO_FRAMES - 22, INTRO_FRAMES], [0, 1], { ...clamp, easing: EASE });
  return (
    <AbsoluteFill
      style={{
        justifyContent: "center",
        alignItems: "center",
        opacity: 1 - out,
        translate: `0px ${-out * 120}px`,
        scale: 1 - out * 0.08,
        filter: `blur(${out * 12}px)`,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 40 }}>
        <Img
          src={staticFile("icon.png")}
          style={{ borderRadius: "23%",
            width: 210,
            height: 210,
            scale: interpolate(frame, [0, 22], [0.4, 1], { ...clamp, easing: EASE_OUT }),
            rotate: `${interpolate(frame, [0, 22], [-16, 0], { ...clamp, easing: EASE_OUT })}deg`,
            opacity: interpolate(frame, [0, 8], [0, 1], clamp),
            filter: "drop-shadow(0 24px 60px rgba(122,162,247,0.35))",
          }}
        />
        <div
          style={{
            fontFamily: SANS,
            fontWeight: 800,
            fontSize: 200,
            letterSpacing: -8,
            color: "#f5f6f8",
            opacity: interpolate(frame, [8, 22], [0, 1], clamp),
            translate: `${interpolate(frame, [8, 28], [-40, 0], { ...clamp, easing: EASE_OUT })}px 0px`,
          }}
        >
          Sich
        </div>
      </div>
      <div
        style={{
          marginTop: 36,
          fontFamily: SANS,
          fontWeight: 500,
          fontSize: 54,
          letterSpacing: -0.6,
          color: "rgba(230,233,240,0.72)",
          opacity: interpolate(frame, [18, 32], [0, 1], clamp),
          translate: `0px ${interpolate(frame, [18, 34], [20, 0], { ...clamp, easing: EASE_OUT })}px`,
        }}
      >
        Stay focused while your agents work
      </div>
    </AbsoluteFill>
  );
};
