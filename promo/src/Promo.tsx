import { AbsoluteFill, Sequence, useVideoConfig } from "remotion";
import { Backdrop } from "./parts/Backdrop";
import { Captions } from "./parts/Captions";
import { Intro } from "./parts/Intro";
import { Stamp } from "./parts/Stamp";
import { Outro } from "./parts/Outro";
import { Stage } from "./parts/Stage";
import { FOOTAGE_FROM, FOOTAGE_SECONDS, INTRO_FRAMES, OUTRO_FRAMES, OUTRO_FROM } from "./timeline";

export const Promo: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill style={{ overflow: "hidden" }}>
      <Backdrop />
      <Sequence name="Intro" durationInFrames={INTRO_FRAMES}>
        <Intro />
      </Sequence>
      <Sequence name="Footage" from={FOOTAGE_FROM} durationInFrames={Math.round(FOOTAGE_SECONDS * fps)}>
        <Stage />
        <Captions />
        <Stamp />
      </Sequence>
      <Sequence name="Outro" from={OUTRO_FROM} durationInFrames={OUTRO_FRAMES}>
        <Outro />
      </Sequence>
    </AbsoluteFill>
  );
};
