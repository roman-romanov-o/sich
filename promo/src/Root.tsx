import { Composition, Still } from "remotion";
import { Clip } from "./Clip";
import { Promo } from "./Promo";
import { Social } from "./Social";
import { CLIPS, FPS, TOTAL_FRAMES, clipFrames } from "./timeline";

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="Promo" component={Promo} durationInFrames={TOTAL_FRAMES} fps={FPS} width={1920} height={1080} />
    {Object.entries(CLIPS).map(([id, cuts]) => (
      <Composition key={id} id={id} component={Clip} defaultProps={{ cuts }} durationInFrames={clipFrames(cuts)} fps={FPS} width={1920} height={1080} />
    ))}
    <Still id="Social" component={Social} width={1280} height={640} />
  </>
);
