import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { B, FOOTAGE_FROM, FPS } from "../timeline";

/** Near-black stage with soft glows; a calm teal one swells through the break.
 * `footageFrom` is the frame where footage time 0 sits in the current sequence. */
export const Backdrop: React.FC<{ footageFrom?: number }> = ({ footageFrom = FOOTAGE_FROM }) => {
  const frame = useCurrentFrame();
  const t = (frame - footageFrom) / FPS;
  const calm = interpolate(t, [B.rest - 0.8, B.rest + 0.4, B.release, B.release + 0.8], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <AbsoluteFill
      style={{
        backgroundColor: "#07080b",
        backgroundImage: [
          `radial-gradient(60% 55% at ${interpolate(frame, [0, 900], [22, 34])}% 18%, rgba(122,162,247,0.20), transparent 70%)`,
          `radial-gradient(55% 50% at 78% ${interpolate(frame, [0, 900], [88, 74])}%, rgba(187,154,247,0.12), transparent 70%)`,
          `radial-gradient(55% 55% at 50% 50%, rgba(125,207,255,${0.26 * calm}), transparent 72%)`,
        ].join(","),
      }}
    >
      <AbsoluteFill
        style={{
          backgroundImage:
            "linear-gradient(rgba(255,255,255,0.025) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.025) 1px, transparent 1px)",
          backgroundSize: "64px 64px",
          maskImage: "radial-gradient(70% 70% at 50% 45%, black, transparent)",
        }}
      />
    </AbsoluteFill>
  );
};
