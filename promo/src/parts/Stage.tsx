import { Video } from "@remotion/media";
import { AbsoluteFill, Easing, interpolate, staticFile, useCurrentFrame } from "remotion";
import { CLICKS, Click, EASE, EASE_OUT, FOOTAGE_SECONDS, FPS, cameraAt } from "../timeline";

const W = 1480;
const H = (W * 1856) / 2880;
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** The recorded app window, flown in at a 3D angle, driven by the camera shots. */
export const Stage: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const cam = cameraAt(t);
  const end = FOOTAGE_SECONDS;
  return (
    <AbsoluteFill style={{ perspective: 2000 }}>
      <AbsoluteFill
        style={{
          opacity: interpolate(t, [0, 0.35, end - 0.5, end], [0, 1, 1, 0], clamp),
          translate: interpolate(t, [0, 1.3, end - 0.7, end], ["0px 280px", "0px 0px", "0px 0px", "0px -60px"], {
            ...clamp,
            easing: EASE_OUT,
          }),
          scale: interpolate(t, [0, 1.3, end - 0.7, end], [0.8, 1, 1, 0.9], { ...clamp, easing: EASE_OUT }),
          rotate: `x ${interpolate(t, [0, 1.4, end - 0.7, end], [28, 0, 0, -12], { ...clamp, easing: EASE_OUT })}deg`,
          filter: `blur(${interpolate(t, [end - 0.6, end], [0, 10], clamp)}px)`,
        }}
      >
        <div
          style={{
            position: "absolute",
            width: W,
            height: H,
            transformOrigin: "0 0",
            translate: `${960 - cam.x * W * cam.zoom}px ${540 - cam.y * H * cam.zoom}px`,
            scale: cam.zoom,
          }}
        >
          <div
            style={{
              position: "absolute",
              inset: 0,
              borderRadius: 14,
              overflow: "hidden",
              boxShadow:
                "0 0 0 1px rgba(255,255,255,0.09), 0 40px 120px rgba(0,0,0,0.65), 0 12px 40px rgba(0,0,0,0.5)",
            }}
          >
            <Video src={staticFile("footage.mp4")} muted style={{ width: "100%", height: "100%" }} />
          </div>
          {CLICKS.map((c) => (
            <Cursor key={c.click} c={c} t={t} zoom={cam.zoom} />
          ))}
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

const Cursor: React.FC<{ c: Click; t: number; zoom: number }> = ({ c, t, zoom }) => {
  const { from: a, to: b } = c;
  const p = interpolate(t, [c.appear, c.arrive], [0, 1], { ...clamp, easing: EASE });
  const press = interpolate(t, [c.click - 0.06, c.click, c.click + 0.12], [1, 0.82, 1], clamp);
  const ring = interpolate(t, [c.click, c.click + 0.45], [0, 1], clamp);
  const visible = interpolate(t, [c.appear, c.appear + 0.25, c.hide - 0.1, c.hide], [0, 1, 1, 0], clamp);
  if (visible === 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: `${(a.x + (b.x - a.x) * p) * 100}%`,
        top: `${(a.y + (b.y - a.y) * p) * 100}%`,
        transformOrigin: "0 0",
        scale: 1 / zoom,
        opacity: visible,
      }}
    >
      {t >= c.click ? (
        <div
          style={{
            position: "absolute",
            left: -40,
            top: -40,
            width: 80,
            height: 80,
            borderRadius: 40,
            border: "3px solid rgba(255,255,255,0.9)",
            scale: interpolate(ring, [0, 1], [0.2, 1.4], { easing: Easing.out(Easing.quad) }),
            opacity: 1 - ring,
          }}
        />
      ) : null}
      <svg width={34} height={46} viewBox="0 0 17 23" style={{ scale: press, transformOrigin: "0 0", filter: "drop-shadow(0 3px 6px rgba(0,0,0,0.5))" }}>
        <path d="M1 1 L1 18.5 L5.4 14.4 L8.3 21.2 L11.2 20 L8.4 13.3 L14.4 13.3 Z" fill="#111" stroke="#fff" strokeWidth={1.4} strokeLinejoin="round" />
      </svg>
    </div>
  );
};
