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
            <CutView cut={cut} length={length} first={i === 0} />
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};

/** One cut: everything inside runs on footage time, so camera, captions and stamps carry over. */
const CutView: React.FC<{ cut: Cut; length: number; first: boolean }> = ({ cut, length, first }) => {
  const frame = useCurrentFrame();
  // Cuts dip in and out of each other, but the clip's first frame is fully lit: GitHub
  // shows it as the poster when a viewer's GIFs don't autoplay.
  const opacity = interpolate(frame, [0, CUT_FADE, length - CUT_FADE, length], [first ? 1 : 0, 1, 1, 0], {
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
