import { AbsoluteFill, interpolate, Sequence, useCurrentFrame } from "remotion";
import { Backdrop } from "./parts/Backdrop";
import { Captions } from "./parts/Captions";
import { Stage } from "./parts/Stage";
import { Stamp } from "./parts/Stamp";
import { CUT_FADE, Cut, FPS } from "./timeline";

/** Footage cuts played back to back, each dipping in and out over the backdrop. */
export const Clip: React.FC<{ cuts: Cut[] }> = ({ cuts }) => {
  let start = 0;
  return (
    <AbsoluteFill style={{ overflow: "hidden", backgroundColor: "#07080b" }}>
      {cuts.map((cut, i) => {
        const length = Math.round((cut.to - cut.from) * FPS);
        const at = start;
        start += length;
        return (
          <Sequence key={i} from={at} durationInFrames={length}>
            <CutView cut={cut} length={length} />
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};

/** One cut: everything inside runs on footage time, so camera, captions and stamps carry over. */
const CutView: React.FC<{ cut: Cut; length: number }> = ({ cut, length }) => {
  const frame = useCurrentFrame();
  // Every cut dips at both ends — including the clip's own ends, so a looping GIF's seam is soft too.
  const opacity = interpolate(frame, [0, CUT_FADE, length - CUT_FADE, length], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <Sequence from={-Math.round(cut.from * FPS)}>
      <Backdrop footageFrom={0} />
      <AbsoluteFill style={{ opacity }}>
        <Stage />
        <Captions />
        <Stamp />
      </AbsoluteFill>
    </Sequence>
  );
};
